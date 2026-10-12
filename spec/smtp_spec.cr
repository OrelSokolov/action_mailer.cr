# SMTP client protocol spec: a fake server records the client dialog
# and answers fixed codes; the oracle can't cover SMTP (no server in
# the bench env), so the RFC 5321 conversation is asserted here.

require "spec"
require "../src/action_mailer_cr"

class SmtpMailer < ActionMailer::Base
  default from: "noreply@example.com"

  def simple(addr : String)
    mail(to: addr, subject: "SMTP", body: "LINE ONE\r\n.LINE TWO")
  end
end

describe "ActionMailer::SmtpClient" do
  it "speaks EHLO/MAIL/RCPT/DATA/QUIT with dot-stuffing" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    received = Channel(Array(String)).new(1)

    spawn do
      client = server.accept
      dialog = [] of String
      client << "220 fake ESMTP\r\n"
      while (line = client.gets("\r\n"))
        dialog << line.chomp("\r\n")
        case line
        when /^EHLO/ then client << "250-fake\r\n250 OK\r\n"
        when /^(MAIL FROM|RCPT TO)/ then client << "250 OK\r\n"
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
      received.send(dialog)
      client.close
    end

    msg = SmtpMailer.simple("bob@example.com").message
    ActionMailer::SmtpClient.new("127.0.0.1", port).send(msg)

    dialog = received.receive
    server.close

    dialog[0].should eq("EHLO localhost")
    dialog[1].should eq("MAIL FROM:<noreply@example.com>")
    dialog[2].should eq("RCPT TO:<bob@example.com>")
    dialog[3].should eq("DATA")
    # dot-stuffing: body line starting with "." is escaped
    dialog.should contain("..LINE TWO")
    dialog.should contain(".")
    dialog[-2].should eq(".")    # DATA terminator right before QUIT
    dialog.last.should eq("QUIT")
    dialog.should contain("From: noreply@example.com")
    dialog.should contain("Subject: SMTP")
  end
end
