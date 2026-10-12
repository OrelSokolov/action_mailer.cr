# Port of ActionMailer::DeliveryMethods (actionmailer 8.1.4): a registry
# of delivery methods (Base.add_delivery_method), the delivery_method
# selector (:smtp/:file/:test, registered symbols, or a DeliveryMethod
# object itself), per-method delivery_settings, raise_delivery_errors,
# and Base.deliver routing. Semantics captured by the oracle dm_* cases.
#
# Deviations (Crystal type system):
#   * Ruby generates a <symbol>_settings class attribute per
#     registration; settings live in one registry keyed by symbol,
#     with smtp_settings/file_settings sugar for the built-ins.
#   * A custom delivery method is a DeliveryMethod subclass (Ruby
#     duck-types klass.new(settings).deliver!(mail)).
#
# File naming follows mail 2.9.1 FileDelivery exactly: one file per
# recipient, named by the address basename, no extension (the .eml
# suffix some expect is NOT what the oracle gem produces).

require "./base"
require "./smtp"
require "file_utils"

module ActionMailer
  # Mail-gem delivery interface: settings-carrying backends responding
  # to deliver!(mail). Built-ins below; register more with
  # Base.add_delivery_method(:symbol, Klass, default_settings).
  abstract class DeliveryMethod
    alias Settings = Hash(String, String | Int32)

    def initialize(@settings : Settings = Settings.new)
    end

    getter settings : Settings

    abstract def deliver!(mail : Mail::Message) : Nil
  end

  class DeliveryError < Exception
  end

  class DeliveryMethod
    # :smtp — the existing SmtpClient (RFC 5321 subset) wired behind
    # the settings hash (address/port).
    class Smtp < DeliveryMethod
      def deliver!(mail : Mail::Message) : Nil
        address = settings["address"]?.as?(String) || "localhost"
        port = case p = settings["port"]?
               when Int32 then p
               when String then p.to_i
               else 25
               end
        SmtpClient.new(address, port).send(mail)
      end
    end

    # :file — mail 2.9.1 FileDelivery: mkdir_p(location), one file per
    # recipient named by the address basename, message + CRLF CRLF.
    class FileDelivery < DeliveryMethod
      def deliver!(mail : Mail::Message) : Nil
        location = settings["location"]?.as?(String) || "tmp/mails"
        FileUtils.mkdir_p(location)
        mail.to.uniq.each do |rcpt|
          File.open(File.join(location, File.basename(rcpt)), "a") do |f|
            f << mail.rfc2822
            f << "\r\n\r\n"
          end
        end
      end
    end

    # :test — Mail::TestMailer semantics: append to Base.deliveries.
    class TestMailer < DeliveryMethod
      def deliver!(mail : Mail::Message) : Nil
        Base.deliveries << mail
      end
    end
  end

  class Base
    # Rails defaults: raise_delivery_errors = true, :smtp delivery.
    class_property? raise_delivery_errors = true
    class_property delivery_method : Symbol | DeliveryMethod = :smtp

    class_getter delivery_methods = {} of Symbol => DeliveryMethod.class
    class_getter delivery_settings = {} of Symbol => DeliveryMethod::Settings

    # Base.add_delivery_method :smtp, DeliveryMethod::Smtp,
    #   {"address" => "localhost", "port" => 25}
    def self.add_delivery_method(symbol : Symbol, klass : DeliveryMethod.class,
                                 default_settings : DeliveryMethod::Settings =
                                   DeliveryMethod::Settings.new) : Nil
      @@delivery_methods[symbol] = klass
      @@delivery_settings[symbol] = default_settings
    end

    def self.delivery_settings(symbol : Symbol) : DeliveryMethod::Settings
      @@delivery_settings[symbol] ||= DeliveryMethod::Settings.new
    end

    def self.smtp_settings : DeliveryMethod::Settings
      delivery_settings(:smtp)
    end

    def self.smtp_settings=(settings : DeliveryMethod::Settings)
      @@delivery_settings[:smtp] = settings
    end

    def self.file_settings : DeliveryMethod::Settings
      delivery_settings(:file)
    end

    def self.file_settings=(settings : DeliveryMethod::Settings)
      @@delivery_settings[:file] = settings
    end

    # Routes a message through the configured delivery method
    # (mail-gem do_delivery semantics): skipped entirely unless
    # perform_deliveries, errors raised only when raise_delivery_errors.
    def self.deliver(msg : Mail::Message) : Nil
      return unless perform_deliveries?
      begin
        case method = delivery_method
        when Symbol
          klass = @@delivery_methods[method]?
          raise RuntimeError.new("Invalid delivery method :#{method}") unless klass
          klass.new(delivery_settings(method)).deliver!(msg)
        else
          method.deliver!(msg)
        end
      rescue ex
        raise ex if raise_delivery_errors?
      end
    end
  end

  Base.add_delivery_method :smtp, DeliveryMethod::Smtp,
    DeliveryMethod::Settings{"address" => "localhost", "port" => 25}
  file_settings = DeliveryMethod::Settings.new
  file_settings["location"] = "tmp/mails"
  Base.add_delivery_method :file, DeliveryMethod::FileDelivery, file_settings
  Base.add_delivery_method :test, DeliveryMethod::TestMailer
end
