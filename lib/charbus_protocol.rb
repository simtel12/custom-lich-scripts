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

    module Channels
      module_function

      def state(prefix, character)    = "#{prefix}:#{character}_state"
      def requests(prefix, character) = "#{prefix}:#{character}_requests"
      def reply(prefix, uuid)         = "#{prefix}:reply:#{uuid}"

      # Redis channel names are byte-exact, so the daemon's XMLData.name casing
      # is canonical. The CLI cannot discover that casing without already having
      # it, so it capitalizes — correct for DR character names (spec §4.1).
      def normalize_character(name)
        s = name.to_s.strip
        s.empty? ? s : (s[0].upcase + s[1..].downcase)
      end
    end

    # Game text arrives ASCII-8BIT (Ox parses with convert_special: false), while
    # map-derived strings are UTF-8. JSON.generate raises on a BINARY string with
    # any byte >= 0x80, which would kill the publisher thread in a restart loop
    # (spec §4.5).
    module Sanitize
      module_function

      def string(str)
        str.dup.force_encoding(Encoding::UTF_8).scrub("?")
      end

      def deep(obj)
        case obj
        when String then string(obj)
        when Array  then obj.map { |v| deep(v) }
        when Hash   then obj.each_with_object({}) { |(k, v), h| h[deep(k)] = deep(v) }
        else obj
        end
      end
    end

    class ConfigError < StandardError; end

    module Config
      REQUIRED_KEYS = %w[
        redis channel_prefix heartbeat self_ping_interval self_ping_timeout
        self_ping_misses reconnect_backoff queue_size event_queue_size
        event_max_age request_max_age expect_max_timeout
      ].freeze

      module_function

      def normalize(raw)
        deep_stringify(raw.respond_to?(:to_h) ? raw.to_h : raw)
      end

      def for_character(raw, name)
        cfg = normalize(raw)
        overrides = (cfg["characters"] || {})[name.to_s] || {}
        merged = deep_merge(cfg, overrides)
        merged.delete("characters")
        merged
      end

      def validate!(cfg)
        raise ConfigError, "charbus config is empty — missing or malformed YAML" if cfg.nil? || cfg.empty?

        missing = REQUIRED_KEYS.reject { |k| cfg.key?(k) }
        raise ConfigError, "charbus config missing keys: #{missing.join(', ')}" unless missing.empty?

        prefix = cfg["channel_prefix"]
        raise ConfigError, "channel_prefix must be a non-empty string" unless prefix.is_a?(String) && !prefix.empty?

        host = cfg.dig("redis", "host")
        raise ConfigError, "redis.host must be a non-empty string" unless host.is_a?(String) && !host.empty?

        cfg
      end

      def deep_stringify(obj)
        case obj
        when Hash  then obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
        when Array then obj.map { |v| deep_stringify(v) }
        else obj
        end
      end

      def deep_merge(base, over)
        base.merge(over) do |_k, a, b|
          a.is_a?(Hash) && b.is_a?(Hash) ? deep_merge(a, b) : b
        end
      end
    end
  end
end
