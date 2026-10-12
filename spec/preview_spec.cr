# Unit specs for ActionMailer::Preview and the /rails/mailers dev
# endpoint (oracle can't cover previews — they need a Rails-app
# context; this mirrors the unit-spec pattern of the other ports).

require "spec"
require "http/server"
require "../src/action_mailer_cr"

class PreviewBenchMailer < ActionMailer::Base
  default from: "noreply@example.com"

  def plain_email(addr : String)
    mail(to: addr, subject: "Plain", body: "PLAIN PREVIEW BODY")
  end

  def fancy_email(addr : String)
    mail(to: addr, subject: "Fancy") do |format|
      format.text { "FANCY TEXT" }
      format.html { "<p>FANCY HTML</p>" }
    end
  end

  def param_email(addr : String)
    mail(to: addr, subject: "Hello #{params["user"]}", body: "PARAM #{params["user"]}")
  end
end

class PreviewBenchMailerPreview < ActionMailer::Preview
  def plain_email : ActionMailer::MessageDelivery
    PreviewBenchMailer.plain_email("bob@example.com")
  end

  def fancy_email : ActionMailer::MessageDelivery
    PreviewBenchMailer.fancy_email("bob@example.com")
  end

  def param_email : ActionMailer::MessageDelivery
    PreviewBenchMailer.with(user: "ann@example.com").param_email("bob@example.com")
  end
end

class ANotherMailerPreview < ActionMailer::Preview
  def welcome : ActionMailer::MessageDelivery
    PreviewBenchMailer.plain_email("bob@example.com")
  end
end

def preview_context(method : String, path : String)
  io = IO::Memory.new
  request = HTTP::Request.new(method, path)
  response = HTTP::Server::Response.new(io)
  {HTTP::Server::Context.new(request, response), io, response}
end

def serve_previews(method : String, path : String)
  context, io, response = preview_context(method, path)
  ActionMailer::PreviewServer.serve?(context).should be_true
  response.close
  {context, io.to_s}
end

describe ActionMailer::Preview do
  it "registers all preview classes sorted by preview_name" do
    ActionMailer::Preview.all.map(&.preview_name).should eq(["a_nother_mailer", "preview_bench_mailer"])
  end

  it "underscored preview_name without the suffix" do
    PreviewBenchMailerPreview.preview_name.should eq("preview_bench_mailer")
    ANotherMailerPreview.preview_name.should eq("a_nother_mailer")
  end

  it "lists public email methods sorted" do
    PreviewBenchMailerPreview.emails.should eq(["fancy_email", "param_email", "plain_email"])
    PreviewBenchMailerPreview.email_exists?("plain_email").should be_true
    PreviewBenchMailerPreview.email_exists?("nope").should be_false
  end

  it "finds previews by name and knows what exists" do
    ActionMailer::Preview.find("preview_bench_mailer").should eq(PreviewBenchMailerPreview)
    ActionMailer::Preview.exists?("a_nother_mailer").should be_true
    ActionMailer::Preview.exists?("nope").should be_false
  end

  it "call builds the message via the preview instance" do
    msg = PreviewBenchMailerPreview.call("plain_email").message
    msg.subject.should eq("Plain")
    msg.body.decoded.should eq("PLAIN PREVIEW BODY")
  end

  it "instance #email dispatches by name and raises for unknown" do
    preview = PreviewBenchMailerPreview.new
    preview.email("param_email").message.subject.should eq("Hello ann@example.com")
    expect_raises(ArgumentError, "Unknown preview email: nope") do
      preview.email("nope")
    end
  end
end

describe "ActionMailer::PreviewServer (/rails/mailers)" do
  it "index lists previews and emails" do
    context, body = serve_previews("GET", "/rails/mailers")
    context.response.status_code.should eq(200)
    body.should contain("<h2>preview_bench_mailer</h2>")
    body.should contain(%(href="/rails/mailers/preview_bench_mailer/plain_email"))
  end

  it "single-email preview renders its body" do
    context, body = serve_previews("GET", "/rails/mailers/preview_bench_mailer/plain_email")
    context.response.status_code.should eq(200)
    body.should contain("PLAIN PREVIEW BODY")
    context.response.headers["Content-Type"].should contain("text/plain")
  end

  it "multipart preview renders the requested part" do
    context, body = serve_previews("GET", "/rails/mailers/preview_bench_mailer/fancy_email?part=text")
    context.response.status_code.should eq(200)
    body.should contain("FANCY TEXT")

    context, body = serve_previews("GET", "/rails/mailers/preview_bench_mailer/fancy_email")
    body.should contain("<p>FANCY HTML</p>")
  end

  it "parameterized preview emails work" do
    context, body = serve_previews("GET", "/rails/mailers/preview_bench_mailer/param_email")
    context.response.status_code.should eq(200)
    body.should contain("PARAM ann@example.com")
  end

  it "unknown preview or email is a 404" do
    context, body = serve_previews("GET", "/rails/mailers/nope/plain_email")
    context.response.status_code.should eq(404)

    context, body = serve_previews("GET", "/rails/mailers/preview_bench_mailer/nope")
    context.response.status_code.should eq(404)
  end

  it "ignores non-GET requests and other paths" do
    context, io, response = preview_context("POST", "/rails/mailers")
    ActionMailer::PreviewServer.serve?(context).should be_false
    context, io, response = preview_context("GET", "/other")
    ActionMailer::PreviewServer.serve?(context).should be_false
  end
end
