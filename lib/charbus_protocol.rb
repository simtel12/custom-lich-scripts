# frozen_string_literal: true

# Pure-Ruby protocol definitions shared by the Lich daemon and the CLI.
#
# HARD RULE: this file must contain no Lich references. It has to `require`
# cleanly in a bare Ruby process, because bin/charbus runs outside Lich and the
# specs run without a game session. See notes/2026-08-14-charbus-design.md §3.2.

require "json"
require "securerandom"

module CharBus
  module Protocol
    VERSION = 1

    class MalformedEnvelope < StandardError; end

    module Envelope
      REQUIRED = %w[v id seq ts from instance type payload].freeze

      module_function

      def encode(type:, from:, instance:, seq:, payload:, id: nil, reply_to: nil, ts: nil)
        msg = {
          "v"        => VERSION,
          "id"       => id || SecureRandom.uuid,
          "seq"      => seq,
          "ts"       => ts || Time.now.to_f,
          "from"     => from,
          "instance" => instance,
          "type"     => type,
          "payload"  => payload
        }
        msg["reply_to"] = reply_to if reply_to
        JSON.generate(msg)
      end

      # Decodes without validating `v`. Version enforcement is the daemon's job
      # (spec §4.2): it must be able to read `id` and `reply_to` from a message
      # whose version it does not support, in order to reply at all.
      def decode(str)
        raw = JSON.parse(str)
        raise MalformedEnvelope, "not an object" unless raw.is_a?(Hash)

        missing = REQUIRED.reject { |k| raw.key?(k) }
        raise MalformedEnvelope, "missing keys: #{missing.join(', ')}" unless missing.empty?
        raise MalformedEnvelope, "payload not an object" unless raw["payload"].is_a?(Hash)

        {
          v: raw["v"], id: raw["id"], seq: raw["seq"], ts: raw["ts"],
          from: raw["from"], instance: raw["instance"], type: raw["type"],
          reply_to: raw["reply_to"], payload: raw["payload"]
        }
      rescue JSON::ParserError => e
        raise MalformedEnvelope, e.message
      end
    end
  end
end
