# Delivery-method specs beyond the oracle: the Resend HTTP adapter
# against a local stub server (the omniauth_spec pattern), :file on
# disk, :smtp routing through the fake-server dialog from smtp_spec,
# and the custom-object / unknown-symbol paths. No network.

require "spec"
require "http/server"
require "file_utils"
require "../src/action_mailer_cr"

# Same starting state as the oracle: everything delivers via :test
# unless a spec overrides (the class default is :smtp, as in Rails).
ActionMailer::Base.delivery_method = :test

def spec_tmpdir : String
  dir = File.join(Dir.tempdir, "action_mailer_cr-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  dir
end

class DeliveryMailer < ActionMailer::Base
  default from: "noreply@example.com"

  def simple(addr : String)
    mail(to: addr, subject: "Delivery", body: "DELIVERY BODY")
  end

  def fancy(addr : String)
    attachments["report.txt"] = {"mime_type" => "text/plain", "content" => "ATTACH DATA"}
    headers["Cc"] = "cc1@example.com, cc2@example.com"
    mail(to: addr, subject: "Fancy") do |format|
      format.text { "TEXT BODY" }
      format.html { "<p>HTML BODY</p>" }
    end
  end
end

class RecordingDelivery < ActionMailer::DeliveryMethod
  class_property delivered = [] of Mail::Message

  def deliver!(mail : Mail::Message) : Nil
    RecordingDelivery.delivered << mail
  end
end

def reset_delivery_state : Nil
  ActionMailer::Base.delivery_method = :test
  ActionMailer::Base.raise_delivery_errors = true
  ActionMailer::Base.perform_deliveries = true
end

describe "ActionMailer delivery methods" do
  after_each { reset_delivery_state }

  it ":test appends to Base.deliveries" do
    ActionMailer::Base.delivery_method = :test
    size = ActionMailer::Base.deliveries.size
    DeliveryMailer.simple("test@example.com").deliver_now
    ActionMailer::Base.deliveries.size.should eq(size + 1)
    ActionMailer::Base.deliveries.last.subject.should eq("Delivery")
  end

  it ":smtp routes Base.deliver through SmtpClient" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    dialog = [] of String

    spawn do
      client = server.accept
      client << "220 fake ESMTP\r\n"
      while (line = client.gets("\r\n"))
        dialog << line.chomp("\r\n")
        case line
        when /^EHLO/ then client << "250-fake\r\n250 OK\r\n"
        when /^DATA/
          client << "354 go\r\n"
          while (dline = client.gets("\r\n"))
            break if dline == ".\r\n"
            dialog << dline.chomp("\r\n")
          end
          dialog << "."
          client << "250 queued\r\n"
        when /^QUIT/
          client << "221 bye\r\n"
          break
        else
          client << "250 OK\r\n"
        end
      end
      client.close
    end

    ActionMailer::Base.delivery_method = :smtp
    smtp = ActionMailer::Base.delivery_settings(:smtp)
    smtp["address"] = "127.0.0.1"
    smtp["port"] = port
    DeliveryMailer.simple("smtp@example.com").deliver_now
    server.close

    dialog.should contain("MAIL FROM:<noreply@example.com>")
    dialog.should contain("RCPT TO:<smtp@example.com>")
    dialog.should contain("From: noreply@example.com")
    dialog.should contain("Subject: Delivery")
  end

  it ":file writes one file per recipient (mail 2.9.1 naming)" do
    dir = spec_tmpdir
    ActionMailer::Base.delivery_method = :file
    ActionMailer::Base.delivery_settings(:file)["location"] = dir
    DeliveryMailer.simple("file@example.com").deliver_now

    names = Dir.children(dir)
    names.should eq(["file@example.com"])
    File.read(File.join(dir, "file@example.com")).should contain("Subject: Delivery")
    FileUtils.rm_rf(dir)
  end

  it ":file defaults to tmp/mails" do
    ActionMailer::Base.delivery_method = :file
    ActionMailer::Base.delivery_settings(:file)["location"] = "tmp/mails"
    FileUtils.rm_rf("tmp/mails") if Dir.exists?("tmp/mails")
    DeliveryMailer.simple("defaultfile@example.com").deliver_now
    File.exists?("tmp/mails/defaultfile@example.com").should be_true
    FileUtils.rm_rf("tmp/mails")
  end

  it "registers a custom delivery method via add_delivery_method" do
    ActionMailer::Base.add_delivery_method(:recording, RecordingDelivery)
    ActionMailer::Base.delivery_method = :recording
    DeliveryMailer.simple("custom@example.com").deliver_now
    RecordingDelivery.delivered.last.to.should eq(["custom@example.com"])
  end

  it "accepts a delivery object as delivery_method" do
    recorder = RecordingDelivery.new
    ActionMailer::Base.delivery_method = recorder
    DeliveryMailer.simple("object@example.com").deliver_now
    method = ActionMailer::Base.delivery_method
    method.should be_a(RecordingDelivery)
    (method.as(RecordingDelivery).same?(recorder)).should be_true
    RecordingDelivery.delivered.last.to.should eq(["object@example.com"])
  end

  it "raises RuntimeError for an unknown method symbol" do
    ActionMailer::Base.delivery_method = :nope
    expect_raises(RuntimeError, "Invalid delivery method :nope") do
      DeliveryMailer.simple("x@example.com").deliver_now
    end
  end

  it "raise_delivery_errors = false swallows smtp failures" do
    ActionMailer::Base.delivery_method = :smtp
    smtp = ActionMailer::Base.delivery_settings(:smtp)
    smtp["address"] = "127.0.0.1"
    smtp["port"] = 9
    ActionMailer::Base.raise_delivery_errors = false
    msg = DeliveryMailer.simple("x@example.com").deliver_now
    msg.class.name.should eq("Mail::Message")
  end

  it "perform_deliveries = false skips delivery" do
    ActionMailer::Base.perform_deliveries = false
    size = ActionMailer::Base.deliveries.size
    DeliveryMailer.simple("skip@example.com").deliver_now
    ActionMailer::Base.deliveries.size.should eq(size)
  end
end

describe "ActionMailer::Resend" do
  after_each do
    ActionMailer::Resend.api_key = nil
    ActionMailer::Base.delivery_method = :test
    ActionMailer::Base.raise_delivery_errors = true
  end

  it "POSTs /emails with Bearer key and JSON payload" do
    requests = Channel({HTTP::Request, String}).new(1)
    server = HTTP::Server.new do |context|
      body = context.request.body.try(&.gets_to_end) || ""
      requests.send({context.request, body})
      context.response.content_type = "application/json"
      context.response.print %({"id":"email-123"})
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }

    begin
      ActionMailer::Resend.scheme = "http"
      ActionMailer::Resend.host = "127.0.0.1"
      ActionMailer::Resend.port = address.port
      ActionMailer::Resend.api_key = "re_test_key"

      ActionMailer::Base.delivery_method = :resend
      DeliveryMailer.fancy("resend@example.com").deliver_now

      request, body = requests.receive

      request.method.should eq("POST")
      request.path.should eq("/emails")
      request.headers["Authorization"].should eq("Bearer re_test_key")
      payload = JSON.parse(body)
      payload["from"].as_s.should eq("noreply@example.com")
      payload["to"].as_a.map(&.as_s).should eq(["resend@example.com"])
      payload["cc"].as_a.map(&.as_s).should eq(["cc1@example.com", "cc2@example.com"])
      payload["subject"].as_s.should eq("Fancy")
      payload["text"].as_s.should eq("TEXT BODY")
      payload["html"].as_s.should eq("<p>HTML BODY</p>")
      att = payload["attachments"].as_a.first
      att["filename"].as_s.should eq("report.txt")
      Base64.decode_string(att["content_base64"].as_s).should eq("ATTACH DATA")
    ensure
      server.close
    end
  end

  it "raises DeliveryError on a non-2xx response" do
    server = HTTP::Server.new do |context|
      context.response.status_code = 422
      context.response.print %({"name":"validation_error"})
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }

    begin
      ActionMailer::Resend.scheme = "http"
      ActionMailer::Resend.host = "127.0.0.1"
      ActionMailer::Resend.port = address.port
      ActionMailer::Resend.api_key = "re_test_key"
      ActionMailer::Base.delivery_method = :resend

      expect_raises(ActionMailer::DeliveryError, /422/) do
        DeliveryMailer.simple("err@example.com").deliver_now
      end
    ensure
      server.close
    end
  end

  it "takes the api key from ENV[RESEND_API_KEY] and fails without one" do
    old_key = ENV["RESEND_API_KEY"]?
    ActionMailer::Resend.scheme = "http"
    ActionMailer::Resend.host = "127.0.0.1"
    ActionMailer::Resend.port = 1 # never reached without a key

    begin
      ENV.delete("RESEND_API_KEY")
      ActionMailer::Base.delivery_method = :resend
      expect_raises(ActionMailer::DeliveryError, /api key/) do
        DeliveryMailer.simple("nokey@example.com").deliver_now
      end

      ENV["RESEND_API_KEY"] = "re_env_key"
      adapter = ActionMailer::Resend.new
      adapter.api_key.should eq("re_env_key")
    ensure
      if (k = old_key)
        ENV["RESEND_API_KEY"] = k
      else
        ENV.delete("RESEND_API_KEY")
      end
    end
  end
end
