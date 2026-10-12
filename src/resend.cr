# Resend (https://resend.com) HTTP delivery adapter: POST
# {scheme}://{host}:{port}/emails with a Bearer api key and a JSON
# payload mapped from Mail::Message. Registered as :resend, so
# `ActionMailer::Base.delivery_method = :resend` starts delivering.
# host/port/scheme are class properties so specs run against a local
# stub (no network); the api key is a hook property defaulting to
# ENV["RESEND_API_KEY"].

require "http/client"
require "base64"
require "./delivery"

module ActionMailer
  class Resend < DeliveryMethod
    class_property host : String = "api.resend.com"
    class_property port : Int32 = 443
    class_property scheme : String = "https"

    # Hook property: when nil, ENV["RESEND_API_KEY"] is used.
    class_property api_key : String? = nil

    def api_key : String
      self.class.api_key || ENV["RESEND_API_KEY"]? ||
        raise DeliveryError.new("Resend api key is not set (Resend.api_key or RESEND_API_KEY)")
    end

    def deliver!(mail : Mail::Message) : Nil
      response = HTTP::Client.new(self.class.host, self.class.port,
        tls: self.class.scheme == "https").post(
          "/emails",
          headers: HTTP::Headers{
            "Authorization" => "Bearer #{api_key}",
            "Content-Type"  => "application/json",
          },
          body: build_payload(mail))
      unless response.success?
        raise DeliveryError.new("Resend API error: #{response.status_code} #{response.body}")
      end
    end

    # {from, to, cc, bcc, subject, html, text,
    #  attachments: [{filename, content_base64}]}
    def build_payload(mail : Mail::Message) : String
      String.build do |io|
        JSON.build(io) do |json|
          json.object do
            if from = mail.from.first?
              json.field("from", from)
            end
            write_addresses(json, "to", mail.to)
            write_addresses(json, "cc", header_addresses(mail, "Cc"))
            write_addresses(json, "bcc", header_addresses(mail, "Bcc"))
            if subject = mail.subject
              json.field("subject", subject)
            end
            if html = part_body(mail, "text/html")
              json.field("html", html)
            end
            if text = part_body(mail, "text/plain")
              json.field("text", text)
            end
            unless mail.attachments.empty?
              json.field("attachments") do
                json.array do
                  mail.attachments.each do |att|
                    json.object do
                      json.field("filename", att.filename)
                      json.field("content_base64", Base64.strict_encode(att.content))
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    private def write_addresses(json : JSON::Builder, field : String,
                                addresses : Array(String)) : Nil
      return if addresses.empty?
      json.field(field) do
        json.array { addresses.each { |a| json.string(a) } }
      end
    end

    # Cc/Bcc live in the extra headers (the DSL has no dedicated field).
    private def header_addresses(mail : Mail::Message, name : String) : Array(String)
      if value = mail.extra_headers[name]?
        value.split(",").map(&.strip).reject(&.empty?)
      else
        [] of String
      end
    end

    private def part_body(mail : Mail::Message, mime : String) : String?
      return mail.body.decoded if mail.mime_type == mime
      mail.parts.find { |p| p.mime_type == mime }.try(&.decoded)
    end
  end

  Base.add_delivery_method :resend, Resend
end
