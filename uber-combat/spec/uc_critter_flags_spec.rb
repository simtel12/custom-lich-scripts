# frozen_string_literal: true

# The enrichment flags harvested from elanthipedia's {{Critter}} infobox:
# skinnable, skin_yields, drops_boxes, construct, undead, cursed, corporeal.
# Spec: notes/uber-combat/43-critter-enrichment.md.
#
# The whole point of these examples is the THREE-STATE rule. Every flag is
# true / false / nil, nil means "elanthipedia does not say", and no reader
# anywhere is allowed to quietly turn that into false.
RSpec.describe UberCombat::Critter do
  def critter(fields)
    described_class.new("Test_creature", { "noun" => "test creature" }.merge(fields))
  end

  describe "the three-state flags" do
    it "reads a true" do
      expect(critter("skinnable" => true).skinnable).to be(true)
    end

    it "reads a false" do
      expect(critter("skinnable" => false).skinnable).to be(false)
    end

    # The one that matters. An absent key is elanthipedia saying Unknown, and
    # it must arrive as nil so a caller has to decide rather than inheriting a
    # decision nobody made.
    it "reads an absent flag as nil, not false" do
      expect(critter({}).skinnable).to be_nil
    end

    it "reads every flag the same way" do
      empty = critter({})

      expect([empty.drops_boxes, empty.construct, empty.undead, empty.cursed, empty.corporeal])
        .to all(be_nil)
    end
  end

  describe "#skin_yields" do
    it "lists what the creature drops" do
      expect(critter("skin_yields" => %w[skin bone]).skin_yields).to eq(%w[skin bone])
    end

    # An empty list and a nil are different answers. Empty is "the page names
    # all three yields as No"; nil is "the page names none of the three".
    it "keeps an empty list distinct from an unknown one" do
      expect([critter("skin_yields" => []).skin_yields, critter({}).skin_yields]).to eq([[], nil])
    end

    it "answers yields? per kind" do
      c = critter("skin_yields" => ["part"])

      expect([c.yields?("part"), c.yields?("skin")]).to eq([true, false])
    end

    it "answers yields? with nil when nothing is recorded" do
      expect(critter({}).yields?("skin")).to be_nil
    end

    # Skinnable is not the same question. The adult desert armadillo is the
    # live case: Skinnable=yes, hasskin=No, haspart=Yes. It yields a plated
    # claw and no hide, so a leg gathering skins must read skin_yields.
    it "can be skinnable and still yield no skin" do
      c = critter("skinnable" => true, "skin_yields" => ["part"])

      expect([c.skinnable, c.yields?("skin")]).to eq([true, false])
    end
  end

  describe "#construct_or_undead" do
    it "is true for a construct" do
      expect(critter("construct" => true, "undead" => false).construct_or_undead).to be(true)
    end

    it "is true for an undead" do
      expect(critter("construct" => false, "undead" => true).construct_or_undead).to be(true)
    end

    it "is false only when both are known false" do
      expect(critter("construct" => false, "undead" => false).construct_or_undead).to be(false)
    end

    # undead and cursed come from one four-way |Evil= field, so an absent
    # field leaves undead nil rather than false. A living creature attacked by
    # an empath is a guild-law violation, not lost yield, so the unknown must
    # survive as an unknown all the way to the caller.
    it "is nil when the alignment is unknown and the creature is not a construct" do
      expect(critter("construct" => false).construct_or_undead).to be_nil
    end

    it "is still true when the alignment is unknown but the creature is a construct" do
      expect(critter("construct" => true).construct_or_undead).to be(true)
    end
  end

  describe "provenance" do
    it "knows when an infobox was actually read" do
      c = critter("provenance" => { "flags" => "elanthipedia_critter_infobox" })

      expect(c.flags_known?).to be(true)
    end

    it "knows when it was not" do
      expect(critter("provenance" => { "flags" => "unresolved" }).flags_known?).to be(false)
    end

    it "reports a page that contradicts itself" do
      c = critter("flags_review" => true, "flags_review_reason" => "Skinnable=yes but no yields")

      expect([c.flags_review?, c.flags_review_reason])
        .to eq([true, "Skinnable=yes but no yields"])
    end

    it "reports no review on an ordinary record" do
      expect(critter({}).flags_review?).to be(false)
    end
  end
end

RSpec.describe UberCombat::CritterFlags do
  # Build a zone whose roster is exactly the named critter keys, and a table
  # holding those records. FakeZoneTable includes the real module, so these
  # examples exercise production code rather than a copy of it.
  def table_with(records, refs)
    zone = UberCombat::Zone.new("test_zone", { "critter_refs" => refs })
    [FakeZoneTable.new([zone], records), zone]
  end

  def yes(flag)
    { flag.to_s => true }
  end

  describe "#critters_in" do
    it "resolves the roster through critter_refs" do
      table, zone = table_with({ "A" => yes(:skinnable) }, { "an ant" => "A" })

      expect(table.critters_in(zone).map(&:key)).to eq(["A"])
    end

    # A ref pointing at a record the dictionary does not hold must still count
    # towards the roster size. Dropping it would shrink the denominator and
    # quietly raise every ratio, which is the fail-open direction.
    it "keeps a dangling ref in the roster as an all-unknown record" do
      table, zone = table_with({}, { "a ghost" => "Missing" })

      expect([table.critters_in(zone).size, table.critters_in(zone).first.skinnable])
        .to eq([1, nil])
    end
  end

  describe "#qualifying_ratio" do
    it "is the fraction of the roster the flag is true for" do
      table, zone = table_with({ "A" => yes(:skinnable), "B" => { "skinnable" => false } },
                               { "a" => "A", "b" => "B" })

      expect(table.qualifying_ratio(zone, "skinnable")).to eq(0.5)
    end

    # An unknown drags the ratio down exactly as a false does. That is the
    # conservative direction: a zone is not promoted to a skinning zone on the
    # strength of creatures nobody has checked.
    it "counts an unknown against, the same as a false" do
      table, zone = table_with({ "A" => yes(:skinnable), "B" => {} }, { "a" => "A", "b" => "B" })

      expect(table.qualifying_ratio(zone, "skinnable")).to eq(0.5)
    end

    # A ratio over nothing is undefined. Answering 0.0 would read as "checked,
    # and none of them qualify", which is a different claim.
    it "is nil for a zone with no roster" do
      table, zone = table_with({}, {})

      expect(table.qualifying_ratio(zone, "skinnable")).to be_nil
    end

    it "refuses a flag that is not one of the seven" do
      table, zone = table_with({}, { "a" => "A" })

      expect { table.qualifying_ratio(zone, "delicious") }.to raise_error(KeyError)
    end
  end

  # The ratio alone cannot say whether a zone missed a threshold on evidence
  # or on ignorance, so the census reports the three counts separately.
  describe "#flag_census" do
    it "separates yes, no and unknown" do
      table, zone = table_with(
        { "A" => yes(:drops_boxes), "B" => { "drops_boxes" => false }, "C" => {} },
        { "a" => "A", "b" => "B", "c" => "C" }
      )

      expect(table.flag_census(zone, "drops_boxes")).to eq({ yes: 1, no: 1, unknown: 1 })
    end
  end

  describe "#all_construct_or_undead?" do
    it "admits a roster of constructs and undead" do
      table, zone = table_with({ "A" => yes(:construct), "B" => yes(:undead) },
                               { "a" => "A", "b" => "B" })

      expect(table.all_construct_or_undead?(zone)).to be(true)
    end

    # A hard all_of with no threshold, per the data file's own mode rules. One
    # living creature here is an empath breaking guild law, not lost yield, so
    # there is no ratio at which it becomes acceptable.
    it "refuses a roster with one living creature" do
      table, zone = table_with(
        { "A" => yes(:construct), "B" => { "construct" => false, "undead" => false } },
        { "a" => "A", "b" => "B" }
      )

      expect(table.all_construct_or_undead?(zone)).to be(false)
    end

    it "refuses a roster with one unknown creature" do
      table, zone = table_with({ "A" => yes(:construct), "B" => {} }, { "a" => "A", "b" => "B" })

      expect(table.all_construct_or_undead?(zone)).to be(false)
    end

    # A zone with nothing recorded cannot promise what lives in it.
    it "refuses an empty roster" do
      table, zone = table_with({}, {})

      expect(table.all_construct_or_undead?(zone)).to be(false)
    end
  end

  describe "#any_loot?" do
    it "is true when one creature is skinnable" do
      table, zone = table_with({ "A" => yes(:skinnable), "B" => {} }, { "a" => "A", "b" => "B" })

      expect(table.any_loot?(zone)).to be(true)
    end

    it "is true when one creature drops boxes" do
      table, zone = table_with({ "A" => yes(:drops_boxes) }, { "a" => "A" })

      expect(table.any_loot?(zone)).to be(true)
    end

    it "is false when the roster is entirely unknown" do
      table, zone = table_with({ "A" => {} }, { "a" => "A" })

      expect(table.any_loot?(zone)).to be(false)
    end
  end
end

# Pinned counts against the committed data file. Each is its own example so a
# single moved number names itself in the failure output.
#
# These numbers move when elanthipedia is re-harvested, and that is the point:
# a rise in the null counts means a page lost its infobox, and a fall means
# somebody filled one in. Re-run notes/uber-combat/tools/add-critter-flags.rb
# to refresh, then move the numbers here deliberately.
RSpec.describe "base-uc-zones.yaml enrichment flags" do
  subject(:table) { UberCombat::ZoneTable.load }

  let(:records) { table.critters.map { |key, data| UberCombat::Critter.new(key, data) } }

  def tally(flag)
    values = records.map { |record| record.public_send(flag) }
    [values.count(true), values.count(false), values.count(nil)]
  end

  # 286 of the 306 pages carry a {{Critter}} infobox. The other 20 are 4
  # missing pages and 16 that are disambiguation stubs, and all seven of their
  # flags are null.
  it "read an infobox for 286 of the 306 records" do
    expect(records.count(&:flags_known?)).to eq(286)
  end

  it "leaves every flag null on the 20 records it could not read" do
    unread = records.reject(&:flags_known?)
    flags = unread.flat_map do |r|
      [r.skinnable, r.skin_yields, r.drops_boxes, r.construct, r.undead, r.cursed, r.corporeal]
    end

    expect([unread.size, flags.compact]).to eq([20, []])
  end

  it "counts skinnable as 177 true, 109 false, 20 unknown" do
    expect(tally(:skinnable)).to eq([177, 109, 20])
  end

  it "counts drops_boxes as 148 true, 138 false, 20 unknown" do
    expect(tally(:drops_boxes)).to eq([148, 138, 20])
  end

  it "counts construct as 30 true, 255 false, 21 unknown" do
    expect(tally(:construct)).to eq([30, 255, 21])
  end

  # undead and cursed share one |Evil= field, so they share an unknown count,
  # and it is larger than construct's: 9 pages carry an infobox with no |Evil=
  # at all, 8 of them constructs whose editors saw no alignment to give.
  it "counts undead as 44 true, 233 false, 29 unknown" do
    expect(tally(:undead)).to eq([44, 233, 29])
  end

  it "counts cursed as 39 true, 238 false, 29 unknown" do
    expect(tally(:cursed)).to eq([39, 238, 29])
  end

  it "never marks one creature both undead and cursed" do
    both = records.select { |r| r.undead == true && r.cursed == true }

    expect(both.map(&:key)).to eq([])
  end

  it "counts corporeal as 270 true, 12 false, 24 unknown" do
    expect(tally(:corporeal)).to eq([270, 12, 24])
  end

  it "records a yield list for 258 creatures and leaves 48 unknown" do
    yields = records.map(&:skin_yields)

    expect([yields.count { |y| y == [] }, yields.count { |y| y && !y.empty? }, yields.count(nil)])
      .to eq([88, 170, 48])
  end

  # 8 pages contradict themselves: |Skinnable= disagrees with the three yield
  # fields. Neither half is resolved in the data. If this rises, the wiki has
  # grown a new inconsistency; if it falls, somebody fixed one.
  it "flags 8 records for review" do
    review = records.select(&:flags_review?)

    expect(review.map(&:key)).to contain_exactly(
      "Cadaverous_blue-belly_crocodile", "Cinderwing_harpy", "Elder_desert_armadillo",
      "Forager_wight", "Ice_archon", "Shadowfrost_moth", "Umbral_moth", "Xala'shar_conjurer"
    )
  end

  it "gives every review record a reason" do
    expect(records.select(&:flags_review?).map(&:flags_review_reason).compact.size).to eq(8)
  end

  describe "the zone rollups" do
    # The empath gate. 75 zones hold nothing but constructs and undead, which
    # is the whole empath-legal hunting map as elanthipedia currently records
    # it. The number can only rise as unknown alignments get filled in.
    it "finds 75 zones an empath may hunt" do
      expect(table.zones.count { |zone| table.all_construct_or_undead?(zone) }).to eq(75)
    end

    it "includes the obvious ones" do
      empath = table.zones.select { |zone| table.all_construct_or_undead?(zone) }.map(&:key)

      expect(empath).to include("granite_gargoyles", "zombie_maulers", "clay_soldier")
    end

    it "finds 293 zones with something worth looting" do
      expect(table.zones.count { |zone| table.any_loot?(zone) }).to eq(293)
    end

    # 29 zones carry no critter_refs roster at all, so every ratio over them is
    # undefined rather than zero.
    it "leaves the ratio undefined for the 29 zones with no roster" do
      expect(table.zones.count { |zone| table.qualifying_ratio(zone, "skinnable").nil? }).to eq(29)
    end

    it "finds 190 zones at or above the 0.6 skinnable threshold" do
      over = table.zones.count { |zone| (r = table.qualifying_ratio(zone, "skinnable")) && r >= 0.6 }

      expect(over).to eq(190)
    end

    it "finds 140 zones at or above the 0.6 drops_boxes threshold" do
      over = table.zones.count { |zone| (r = table.qualifying_ratio(zone, "drops_boxes")) && r >= 0.6 }

      expect(over).to eq(140)
    end

    it "finds 31 zones at or above the 0.6 cursed threshold" do
      over = table.zones.count { |zone| (r = table.qualifying_ratio(zone, "cursed")) && r >= 0.6 }

      expect(over).to eq(31)
    end
  end
end
