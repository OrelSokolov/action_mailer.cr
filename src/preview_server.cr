# /rails/mailers — дев-эндпоинт превью писем (аналог маршрута
# ActionMailer::Railtie + Rails::MailersController). Живёт в
# action_mailer_cr, использует только stdlib HTTP; монтируется в
# приложении через CRails.dev_endpoints (railties_cr не зависит от
# action_mailer_cr — см. railties.cr/PLAN.md):
#
#   CRails.dev_endpoints["/rails/mailers"] = ->(ctx : HTTP::Server::Context) {
#     ActionMailer::PreviewServer.serve?(ctx)
#   }
#
# Пути: GET /rails/mailers (индекс), /rails/mailers/:preview (список
# писем), /rails/mailers/:preview/:email?part=html|text (тело письма;
# part выбирается по mime-типу, по умолчанию text/html).

require "http/server"

module ActionMailer
  module PreviewServer
    def self.serve?(context : HTTP::Server::Context) : Bool
      return false unless {"GET", "HEAD"}.includes?(context.request.method)
      path = context.request.path
      if path == "/rails/mailers"
        index(context)
      elsif path.starts_with?("/rails/mailers/")
        show(context, path.lchop("/rails/mailers/"))
      else
        return false
      end
      true
    rescue ex : ArgumentError
      not_found(context, ex.message.to_s)
      true
    end

    private def self.index(context : HTTP::Server::Context) : Nil
      body = String.build do |io|
        io << "<!doctype html><html><head><meta charset=\"utf-8\""
        io << "><title>Mailer Previews</title></head><body>"
        io << "<h1>Mailer previews</h1>"
        if Preview.all.empty?
          io << "<p>No previews defined.</p>"
        end
        Preview.all.each do |preview|
          io << "<h2>#{preview.preview_name}</h2><ul>"
          preview.emails.each do |email|
            io << %(<li><a href="/rails/mailers/#{preview.preview_name}/#{email}">)
            io << email << "</a></li>"
          end
          io << "</ul>"
        end
        io << "</body></html>"
      end
      html(context, body)
    end

    private def self.show(context : HTTP::Server::Context, slug : String) : Nil
      segments = slug.split('/')
      preview = Preview.find(segments[0]? || "")
      raise ArgumentError.new("Unknown preview: #{segments[0]?}") unless preview

      if segments.size == 1
        return index(context)
      end

      email = segments[1]
      raise ArgumentError.new("Unknown email: #{email}") unless preview.email_exists?(email)

      result = preview.call(email)
      message = result.is_a?(MessageDelivery) ? result.message : result
      requested = context.request.query_params["part"]? == "text" ? "text/plain" : "text/html"

      if message.multipart?
        part = message.parts.find { |p| p.mime_type == requested } || message.parts.first?
        if part
          return respond(context, part.decoded, part.mime_type)
        end
      end
      respond(context, message.body.decoded, message.mime_type)
    end

    private def self.respond(context : HTTP::Server::Context, body : String,
                             content_type : String) : Nil
      context.response.status_code = 200
      context.response.headers["Content-Type"] =
        content_type.starts_with?("text/") ? "#{content_type}; charset=utf-8" : content_type
      context.response.print body
    end

    private def self.html(context : HTTP::Server::Context, body : String) : Nil
      respond(context, body, "text/html")
    end

    private def self.not_found(context : HTTP::Server::Context, message : String) : Nil
      context.response.status_code = 404
      context.response.headers["Content-Type"] = "text/plain; charset=utf-8"
      context.response.print message
    end
  end
end
