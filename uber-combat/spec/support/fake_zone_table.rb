# frozen_string_literal: true

# A zone table built from synthetic zones, for tests that must control bands
# exactly rather than depend on the committed data file.
class FakeZoneTable
  attr_reader :zones, :critters

  def initialize(zones, critters = {})
    @zones = zones
    @critters = critters
  end

  def zone(key)
    @zones.find { |z| z.key == key }
  end
end
