# frozen_string_literal: true

require "redis"
require "securerandom"

# Requires a live Redis: docker run -d --rm -p 6379:6379 redis:7-alpine
RSpec.describe "reply-channel ordering", :integration do
  let(:prefix) { "charbustest#{SecureRandom.hex(3)}" }
  let(:redis)  { Redis.new(host: "127.0.0.1", port: 6379) }

  after { redis.close }

  it "loses the reply when the requester publishes before subscribing" do
    reply_channel = CharBus::Protocol::Channels.reply(prefix, SecureRandom.uuid)

    # Responder answers immediately on the request channel.
    responder = Thread.new do
      r = Redis.new(host: "127.0.0.1", port: 6379)
      r.subscribe(CharBus::Protocol::Channels.requests(prefix, "Test")) do |on|
        on.message { |_c, _m| r.publish(reply_channel, "pong"); throw :done }
      end
    rescue StandardError
      nil
    end
    sleep 0.3

    redis.publish(CharBus::Protocol::Channels.requests(prefix, "Test"), "req")
    sleep 0.3

    got = nil
    sub = Redis.new(host: "127.0.0.1", port: 6379)
    t = Thread.new { sub.subscribe_with_timeout(1, reply_channel) { |on| on.message { |_c, m| got = m } } rescue nil }
    t.join

    expect(got).to be_nil    # documents WHY the CLI must subscribe first
    responder.kill
    sub.close
  end

  it "receives the reply when the requester subscribes first" do
    reply_channel = CharBus::Protocol::Channels.reply(prefix, SecureRandom.uuid)
    ready = Queue.new
    got = Queue.new

    listener = Thread.new do
      s = Redis.new(host: "127.0.0.1", port: 6379)
      s.subscribe(reply_channel) do |on|
        on.subscribe { ready << true }
        on.message { |_c, m| got << m; s.unsubscribe }
      end
    end

    ready.pop                                   # subscription confirmed
    redis.publish(reply_channel, "pong")

    expect(got.pop).to eq("pong")
    listener.join(2)
  end
end
