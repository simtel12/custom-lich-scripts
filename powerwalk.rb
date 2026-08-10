# frozen_string_literal: true

# Extractable powerwalk helper for ;pwgo2 (and later go2 / DRCT).
# After a successful room move, optionally send a perceive command and wait RT.
module Powerwalk
  remove_const(:LUNAR_PERCEIVE_COMMANDS) if const_defined?(:LUNAR_PERCEIVE_COMMANDS, false)
  LUNAR_PERCEIVE_COMMANDS = ['mana', 'moons in sky', 'planets'].freeze

  # Hard DR mindstate ceiling — no useful learning at/above this.
  remove_const(:MINDSTATE_CAP) if const_defined?(:MINDSTATE_CAP, false)
  MINDSTATE_CAP = 34

  remove_const(:DEFAULTS) if const_defined?(:DEFAULTS, false)
  DEFAULTS = {
    'powerwalk' => false,
    'avoid_perceive_in_rooms' => [],
    'powerwalk_in_hunting_areas' => false,
    'perceive_health' => true,
    'mindstate_cap' => MINDSTATE_CAP
  }.freeze

  remove_const(:PERCEIVE_MATCHES) if const_defined?(:PERCEIVE_MATCHES, false)
  PERCEIVE_MATCHES = [
    /You fail to sense/i,
    /You're not ready to do that again, yet/i,
    /You reach out/i,
    /You sense:/i,
    /Roundtime/i,
    /Something in the area is interfering/i,
    /attunement/i,
    /\.\.\.wait/i
  ].freeze

  @lunar_perceive_index = -1
  @hunting_room_ids = nil
  @capped_notice_shown = false

  class << self
    attr_accessor :lunar_perceive_index

    def resolve_settings(yaml_hash, overrides = {})
      base = DEFAULTS.dup
      normalize_hash(yaml_hash).each do |key, value|
        next unless base.key?(key)

        base[key] = coerce_value(key, value)
      end
      normalize_hash(overrides).each do |key, value|
        next unless base.key?(key)
        next if value.nil?

        base[key] = coerce_value(key, value)
      end
      base
    end

    def hunting_room_ids
      return @hunting_room_ids if @hunting_room_ids

      zones = get_data('hunting').hunting_zones
      ids = if zones.respond_to?(:values)
              zones.values.flatten
            else
              []
            end
      @hunting_room_ids = ids.compact.map(&:to_i).uniq
    end

    def reset_caches!
      @hunting_room_ids = nil
      @lunar_perceive_index = -1
      @capped_notice_shown = false
    end

    def in_hunting_area?(room_id)
      hunting_room_ids.include?(room_id.to_i)
    end

    def should_perceive?(room_id, settings)
      return false unless truthy?(settings['powerwalk'])
      return false if mindstate_capped?(settings)

      rid = room_id.to_i
      avoid = Array(settings['avoid_perceive_in_rooms']).map(&:to_i)
      return false if avoid.include?(rid)
      return false if !truthy?(settings['powerwalk_in_hunting_areas']) && in_hunting_area?(rid)

      true
    end

    # Empath health mode trains Empathy; all other perceive modes train Attunement.
    def skill_for_settings(settings)
      if empath? && truthy?(settings['perceive_health'])
        'Empathy'
      else
        'Attunement'
      end
    end

    def mindstate_for(settings)
      skill = skill_for_settings(settings)
      Lich::DragonRealms::DRSkill.getxp(skill).to_i
    end

    def mindstate_cap_for(settings)
      cap = settings['mindstate_cap']
      cap.nil? ? MINDSTATE_CAP : cap.to_i
    end

    def mindstate_capped?(settings)
      mindstate_for(settings) >= mindstate_cap_for(settings)
    end

    def lunar_mage?
      stats = Lich::DragonRealms::DRStats
      stats.moon_mage? || stats.trader?
    end

    def empath?
      Lich::DragonRealms::DRStats.empath?
    end

    def next_perceive_command(settings)
      if empath? && truthy?(settings['perceive_health'])
        'perceive health'
      elsif lunar_mage?
        @lunar_perceive_index = (@lunar_perceive_index + 1) % LUNAR_PERCEIVE_COMMANDS.length
        "perceive #{LUNAR_PERCEIVE_COMMANDS[@lunar_perceive_index]}"
      else
        'perceive'
      end
    end

    # After a successful move into room_id. No-op when disabled/avoided/hunting-gated/capped.
    # On Empath health "fail to sense"/"not ready" (neither costs roundtime), falls back to a
    # plain perceive once so the walk still trains Attunement instead of getting nothing.
    def maybe_perceive_after_move(room_id, settings)
      unless truthy?(settings['powerwalk'])
        return false
      end

      if mindstate_capped?(settings)
        unless @capped_notice_shown
          skill = skill_for_settings(settings)
          echo "Powerwalk: skipping perceive — #{skill} mindstate " \
               "#{mindstate_for(settings)} >= cap #{mindstate_cap_for(settings)}"
          @capped_notice_shown = true
        end
        return false
      end

      return false unless should_perceive?(room_id, settings)

      command = next_perceive_command(settings)
      result = DRC.bput(command, *PERCEIVE_MATCHES)
      if command == 'perceive health' && result =~ /You fail to sense|You're not ready to do that again, yet/i
        DRC.bput('perceive', *PERCEIVE_MATCHES)
      end
      waitrt?
      true
    end

    def parse_on_off(value)
      case value.to_s.strip.downcase
      when 'on', 'true', '1', 'yes' then true
      when 'off', 'false', '0', 'no' then false
      end
    end

    private

    def truthy?(value)
      value == true || value.to_s.strip.downcase =~ /^(?:true|on|1|yes)$/
    end

    def coerce_value(key, value)
      case key
      when 'avoid_perceive_in_rooms'
        Array(value).map(&:to_i)
      when 'mindstate_cap'
        value.to_i
      when 'powerwalk', 'powerwalk_in_hunting_areas', 'perceive_health'
        parsed = parse_on_off(value)
        parsed.nil? ? !!value : parsed
      else
        value
      end
    end

    def normalize_hash(obj)
      return {} if obj.nil?

      hash = if obj.is_a?(Hash)
               obj
             elsif obj.respond_to?(:to_h)
               obj.to_h
             else
               {}
             end
      hash.each_with_object({}) do |(key, value), result|
        result[key.to_s] = value
      end
    end
  end
end
