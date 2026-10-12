# ActionMailer::Base — DSL port (P0): default from:, mail(to:/subject:/body:)
# with a format collector (format.text/format.html), attachments[],
# headers[], class-level action methods → MessageDelivery (lazy).
# Delivery routing (Base.deliver / delivery_methods) lives in delivery.cr.

require "./mail"

module ActionMailer
  VERSION = "0.1.0"

  # Compile-time registry of mailer classes (for the generated
  # class-level action methods below).
  MAILERS = [] of Nil

  # Lazy delivery proxy — the explicit facade Rails builds with
  # method_missing; we enumerate the used methods instead.
  class MessageDelivery
    @cached : Mail::Message?
    @params : Hash(String, ActiveJob::ArgValue)?

    def initialize(@mailer_name : String, @action : String,
                   @args : Array(ActiveJob::ArgValue),
                   @builder : Proc(Mail::Message),
                   @params : Hash(String, ActiveJob::ArgValue)? = nil)
    end

    def message : Mail::Message
      @cached ||= @builder.call
    end

    def deliver_now : Mail::Message
      msg = message
      Base.deliver(msg)
      msg
    end

    # Enqueues a MailDeliveryJob instead of delivering (Rails 8.1
    # argument shape, queue :mailers). Parameterized deliveries carry
    # the `.with(...)` params as an extra `params:` kwarg (Rails:
    # parameterized.rb enqueue_delivery). Ruby's param keys are
    # symbols, which ActiveJob serializes as strings plus the
    # `_aj_symbol_keys` marker — the port's keys are strings already,
    # so the marker is emitted here (and skipped when the job applies
    # the params) to keep job arguments byte-identical.
    def deliver_later(*, wait : Time::Span? = nil) : ActiveJob::Base?
      params = {} of String | Symbol => ActiveJob::ArgValue
      keywords = ["args"]
      if mailer_params = @params
        serialized = {} of String | Symbol => ActiveJob::ArgValue
        mailer_params.each { |k, v| serialized[k] = v }
        serialized["_aj_symbol_keys"] = mailer_params.keys.map(&.as(ActiveJob::ArgValue))
        params["params"] = serialized
        keywords = ["params", "args"]
      end
      params["args"] = @args
      params["_aj_ruby2_keywords"] = keywords.map(&.as(ActiveJob::ArgValue))
      job = MailDeliveryJob.set(wait: wait)
      job.perform_later(@mailer_name, @action, "deliver_now", params)
    end
  end

  # format.text { "..." } / format.html { "..." } collector passed to
  # the mail(...) block.
  class FormatCollector
    getter text_bodies = [] of String
    getter html_bodies = [] of String

    def text(&block : -> String) : Nil
      text_bodies << block.call
    end

    def html(&block : -> String) : Nil
      html_bodies << block.call
    end
  end

  # attachments["x.txt"] = {mime_type: ..., content: ...}
  class AttachmentsProxy
    getter entries = [] of {String, String, String} # filename, mime, content

    def []=(filename : String, spec : Hash(String, String)) : Nil
      entries << {filename,
                  spec["mime_type"]? || "application/octet-stream",
                  spec["content"]? || ""}
    end

    def attach(filename : String, mime_type : String, content : String) : Nil
      entries << {filename, mime_type, content}
    end

    def empty? : Bool
      entries.empty?
    end
  end

  class HeadersProxy
    getter entries = {} of String => String

    def []=(name : String, value : String) : Nil
      entries[name] = value
    end
  end

  class Base
    class_property deliveries = [] of Mail::Message
    class_property? perform_deliveries = true

    getter attachments_proxy = AttachmentsProxy.new
    getter headers_proxy = HeadersProxy.new
    getter __message : Mail::Message?

    # Parameterized mailers: params given via `.with(user: ...)`;
    # empty hash by default (Ruby: `@params ||= {}`). Keys are strings
    # (Ruby's are symbols — Crystal cannot mint runtime symbols; job
    # serialization emits ActiveJob's `_aj_symbol_keys` marker for
    # byte-identical arguments, see MessageDelivery#deliver_later).
    @params : Hash(String, ActiveJob::ArgValue)?

    def params : Hash(String, ActiveJob::ArgValue)
      @params ||= {} of String => ActiveJob::ArgValue
    end

    def params=(params : Hash(String, ActiveJob::ArgValue)) : Nil
      @params = params
    end

    # `Mailer.with(user: u)` — returns the Parameterized wrapper whose
    # action twins build Parameterized::MessageDelivery (overridden per
    # subclass by end-of-program codegen below).
    def self.with(**params) : Parameterized::Mailer
      Parameterized::Mailer.new(self, params_hash(params))
    end

    def self.params_hash(params : NamedTuple) : Hash(String, ActiveJob::ArgValue)
      h = {} of String => ActiveJob::ArgValue
      params.each { |k, v| h[k.to_s] = ActiveJob::Serialization.to_arg(v) }
      h
    end

    macro inherited
      {% ::ActionMailer::MAILERS << @type %}
    end

    # default from: "..." — P0 covers :from only.
    macro default(**opts)
      {% if opts[:from] %}
        def __default_from : String
          {{ opts[:from] }}
        end
      {% end %}
    end

    def __default_from : String?
      nil
    end

    # Overridden per-subclass by end-of-program codegen (below).
    def self.__deliver(action : String, args : Array(ActiveJob::ArgValue),
                       params : Hash(String, ActiveJob::ArgValue)? = nil) : Mail::Message
      raise ArgumentError.new("Unknown mailer action: #{action}")
    end

    def attachments : AttachmentsProxy
      @attachments_proxy
    end

    def headers : HeadersProxy
      @headers_proxy
    end

    def mail(to : String? = nil, subject : String? = nil, body : String? = nil) : Mail::Message
      mail(to: to, subject: subject, body: body) { |_| }
    end

    def mail(to : String? = nil, subject : String? = nil,
             body : String? = nil, &block : FormatCollector -> Nil) : Mail::Message
      msg = Mail::Message.new
      msg.from = __default_from
      msg.to = to
      msg.subject = subject
      headers_proxy.entries.each { |k, v| msg[k] = v }

      collector = FormatCollector.new
      yield collector

      # Assemble the message shape the way ActionMailer+mail do:
      #   0 formats + body: → single text/plain
      #   1 format          → single part of that type
      #   2 formats         → multipart/alternative
      #   + attachments     → wrapped in multipart/mixed
      collector.text_bodies.each { |b| msg.add_part("text/plain", b) }
      collector.html_bodies.each { |b| msg.add_part("text/html", b) }

      if msg.parts.empty?
        msg.set_single_body(body || "", "text/plain")
      elsif msg.parts.size == 1
        msg.set_single_body(msg.parts.first.decoded, msg.parts.first.mime_type)
      else
        msg.set_multipart("multipart/alternative")
      end

      attachments_proxy.entries.each do |filename, mime, content|
        msg.add_attachment(filename, mime, content)
      end
      unless attachments_proxy.empty?
        msg.set_multipart("multipart/mixed")
      end

      @__message = msg
      msg
    end
  end
end

# End-of-program codegen: for every mailer class, each public instance
# method (the "actions") gets a class-level twin returning a lazy
# MessageDelivery — the analog of Rails' class-level method_missing —
# plus a serialized-args dispatcher (`__deliver`) used by
# MailDeliveryJob, and a name lookup (`ActionMailer.lookup_mailer`).
macro finished
  {% for m in ::ActionMailer::MAILERS %}
    class {{ m.id }}
      {% for meth in m.methods %}
        {% if meth.visibility != :private && meth.visibility != :protected && meth.name.stringify != "initialize" && !meth.name.stringify.starts_with?("__") && meth.name.stringify != "attachments" && meth.name.stringify != "headers" && meth.name.stringify != "mail" && meth.name.stringify != "params" && meth.name.stringify != "params=" %}
          def self.{{ meth.name.id }}({{ meth.args.splat }})
            mailer = new
            delivery_args = [ {% for a in meth.args %}ActiveJob::Serialization.to_arg({{ a.name.id }}), {% end %} ] of ActiveJob::ArgValue
            builder = -> : Mail::Message do
              mailer.{{ meth.name.id }}({% for a in meth.args %}{{ a.name.id }}, {% end %})
              mailer.__message.not_nil!
            end
            ::ActionMailer::MessageDelivery.new({{ m.name.stringify }}, {{ meth.name.stringify }}, delivery_args, builder)
          end
        {% end %}
      {% end %}

      # `Mailer.with(user: u)` — parameterized twin (Rails'
      # ActionMailer::Parameterized::Mailer): the same class-level
      # action methods, but the mailer instance receives the params.
      def self.with(**params) : ::ActionMailer::Parameterized::Mailer
        Parameterized.new(::ActionMailer::Base.params_hash(params))
      end

      class Parameterized < ::ActionMailer::Parameterized::Mailer
        def initialize(params : Hash(String, ActiveJob::ArgValue))
          super({{ m.id }}, params)
        end

        {% for meth in m.methods %}
          {% if meth.visibility != :private && meth.visibility != :protected && meth.name.stringify != "initialize" && !meth.name.stringify.starts_with?("__") && meth.name.stringify != "attachments" && meth.name.stringify != "headers" && meth.name.stringify != "mail" && meth.name.stringify != "params" && meth.name.stringify != "params=" %}
            def {{ meth.name.id }}({{ meth.args.splat }})
              delivery_args = [ {% for a in meth.args %}ActiveJob::Serialization.to_arg({{ a.name.id }}), {% end %} ] of ActiveJob::ArgValue
              mailer_params = @params
              builder = -> : Mail::Message do
                mailer = {{ m.id }}.new
                mailer.params = mailer_params
                mailer.{{ meth.name.id }}({% for a in meth.args %}{{ a.name.id }}, {% end %})
                mailer.__message.not_nil!
              end
              ::ActionMailer::Parameterized::MessageDelivery.new({{ m.name.stringify }}, {{ meth.name.stringify }}, delivery_args, builder, @params)
            end
          {% end %}
        {% end %}
      end

      def self.__deliver(action : String, args : Array(ActiveJob::ArgValue),
                         params : Hash(String, ActiveJob::ArgValue)? = nil) : Mail::Message
        mailer = new
        mailer.params = params if params
        {% for meth in m.methods %}
          {% if meth.visibility != :private && meth.visibility != :protected && meth.name.stringify != "initialize" && !meth.name.stringify.starts_with?("__") && meth.name.stringify != "attachments" && meth.name.stringify != "headers" && meth.name.stringify != "mail" && meth.name.stringify != "params" && meth.name.stringify != "params=" %}
            {% arg_count = meth.args.size %}
            if action == {{ meth.name.stringify }} && args.size == {{ arg_count }}
              mailer.{{ meth.name.id }}(
                {% i = 0 %}
                {% for a in meth.args %}
                  {% if a.restriction %}
                    args[{{ i }}].as({{ a.restriction }}),
                  {% else %}
                    args[{{ i }}],
                  {% end %}
                  {% i += 1 %}
                {% end %}
              )
              return mailer.__message.not_nil!
            end
          {% end %}
        {% end %}
        raise ArgumentError.new("Unknown mailer action: #{action}")
      end
    end
  {% end %}

  def ActionMailer.lookup_mailer(name : String)
    {% for m in ::ActionMailer::MAILERS %}
      return {{ m.id }} if name == {{ m.name.stringify }}
    {% end %}
    nil
  end

  {% if ::ActionMailer.has_constant?("PREVIEWS") %}
    # --- ActionMailer::Preview codegen (see src/preview.cr) ------------
    {% for p in ::ActionMailer::PREVIEWS %}
      class {{ p.id }}
        # Public email previews (Rails: public_instance_methods(false)).
        def self.emails : Array(String)
          ([ {% for meth in p.methods %}{% if meth.visibility != :private && meth.visibility != :protected && meth.name.stringify != "initialize" && !meth.name.stringify.starts_with?("__") && meth.name.stringify != "params" %}{{ meth.name.stringify }},{% end %}{% end %} ] of String).sort
        end

        def self.email_exists?(email : String) : Bool
          emails.includes?(email)
        end

        # Builds the preview instance with params and calls the email
        # method (Rails: `new(params).public_send(email)`).
        def self.call(email : String, params : Hash(String, ActiveJob::ArgValue) = {} of String => ActiveJob::ArgValue)
          new(params).email(email)
        end

        # String-dispatch twin of Ruby's public_send — previews are
        # compile-time known, so a case ladder replaces reflection.
        def email(method_name : String)
          case method_name
          {% for meth in p.methods %}
            {% if meth.visibility != :private && meth.visibility != :protected && meth.name.stringify != "initialize" && !meth.name.stringify.starts_with?("__") && meth.name.stringify != "params" %}
              when {{ meth.name.stringify }} then {{ meth.name.id }}
            {% end %}
          {% end %}
          else
            raise ArgumentError.new("Unknown preview email: #{method_name}")
          end
        end
      end
    {% end %}

    class ::ActionMailer::Preview
      def self.all : Array(::ActionMailer::Preview.class)
        [ {% for p in ::ActionMailer::PREVIEWS %} {{ p.id }}, {% end %} ] of ::ActionMailer::Preview.class
          .sort_by(&.preview_name)
      end

      def self.exists?(preview_name : String) : Bool
        all.any? { |p| p.preview_name == preview_name }
      end

      def self.find(preview_name : String) : ::ActionMailer::Preview.class | Nil
        all.find { |p| p.preview_name == preview_name }
      end
    end
  {% end %}
end
