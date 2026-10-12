# MailDeliveryJob — the ActiveJob bridge for deliver_later, mirroring
# Rails 8.1: arguments are [mailer_class_name, action, delivery_method,
# {"args" => [...], "_aj_ruby2_keywords" => ["args"]}], queue :mailers.

module ActionMailer
  class MailDeliveryJob < ActiveJob::Base
    def perform(mailer_name, action, delivery_method, params)
      klass = ActionMailer.lookup_mailer(mailer_name.as(String))
      raise ArgumentError.new("Unknown mailer: #{mailer_name}") unless klass

      kwargs = params.as(Hash(String | Symbol, ActiveJob::ArgValue))
      args = if (a = kwargs["args"]?).nil?
               [] of ActiveJob::ArgValue
             else
               a.as(Array(ActiveJob::ArgValue))
             end
      # `.with(...)` params ride along as the "params" kwarg (Rails 8.1
      # parameterized enqueue_delivery); ActiveJob's _aj_* markers are
      # skipped when applying them to the mailer instance.
      mailer_params : Hash(String, ActiveJob::ArgValue)? = nil
      if raw = kwargs["params"]?
        mailer_params = {} of String => ActiveJob::ArgValue
        raw.as(Hash(String | Symbol, ActiveJob::ArgValue)).each do |k, v|
          mailer_params.not_nil![k.to_s] = v unless k.to_s.starts_with?("_aj_")
        end
      end

      msg = klass.__deliver(action.as(String), args, mailer_params)
      case delivery_method.as(String)
      when "deliver_now!"
        Base.deliver(msg) # bang variant skips callbacks (none in P0)
      else
        Base.deliver(msg)
      end
      nil
    end
  end
end
