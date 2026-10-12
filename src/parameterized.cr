# ActionMailer::Parameterized — порт parameterized.rb 8.1.4:
# `Mailer.with(params).action` — обёртка над классом мейлера, чьи
# action-твиновы строят Parameterized::MessageDelivery, несущий params
# (инстансу мейлера они попадают в `params`, для deliver_later —
# сериализуются в kwargs MailDeliveryJob: params/args).

module ActionMailer
  module Parameterized
    # Обёртка, возвращаемая `Mailer.with(...)`. Action-твины генерируются
    # в каждый мейлер-класс макросом finished (аналог Rails' method_missing
    # прокси). Класс нужен ради иерархии Parameterized::MessageDelivery
    # (имя класса оракул фиксирует).
    class Mailer
      getter mailer_class : Base.class
      getter params : Hash(String, ActiveJob::ArgValue)

      def initialize(@mailer_class : Base.class,
                     @params : Hash(String, ActiveJob::ArgValue) = {} of String => ActiveJob::ArgValue)
      end
    end

    # MessageDelivery с params: deliver_later кладёт их в args джобы
    # (`params:`/`args:` kwargs, как enqueue_delivery в parameterized.rb).
    class MessageDelivery < ::ActionMailer::MessageDelivery
    end
  end
end
