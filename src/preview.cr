# ActionMailer::Preview — порт preview.rb 8.1.4.
#
# `class UserMailerPreview < ActionMailer::Preview` — реестр на
# compile-time (macro inherited, как MAILERS в base.cr — замена Ruby's
# DescendantsTracker + Dir-загрузки preview_paths): в компилируемом
# языке preview-классы известны при сборке, никакого require по glob на
# runtime. `Preview.all/find/emails/call` и instance `#email(name)`
# генерируются макросом finished в base.cr.

module ActionMailer
  PREVIEWS = [] of Nil

  class Preview
    getter params : Hash(String, ActiveJob::ArgValue)

    def initialize(@params : Hash(String, ActiveJob::ArgValue) = {} of String => ActiveJob::ArgValue)
    end

    macro inherited
      {% ::ActionMailer::PREVIEWS << @type %}
    end

    # "UserMailerPreview" → "user_mailer" (underscored, no suffix).
    # Runtime `to_s` (the class name) so it stays correct through
    # virtual dispatch from Preview.all.
    def self.preview_name : String
      to_s.rchop("Preview").underscore
    end

    # Overridden per subclass by end-of-program codegen (base.cr):
    # the compile-time-known public email methods.
    def self.emails : Array(String)
      [] of String
    end

    def self.email_exists?(email : String) : Bool
      emails.includes?(email)
    end

    # Builds the preview instance with params and calls the email
    # method (Rails: `new(params).public_send(email)`).
    def self.call(email : String, params : Hash(String, ActiveJob::ArgValue) = {} of String => ActiveJob::ArgValue)
      new(params).email(email)
    end

    # String-dispatch twin of Ruby's public_send — replaced per subclass
    # by a case ladder over the compile-time-known methods.
    def email(method_name : String)
      raise ArgumentError.new("Unknown preview email: #{method_name}")
    end
  end
end
