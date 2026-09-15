# frozen_string_literal: true

# Spec: notes/uber-combat/31-trigger-layer-spec.md rows 6, 7, 8 and 11, with
# the five deviations listed at the top of lib/uc_town.rb.
RSpec.describe UberCombat::Town do
  let(:now) { 1_800_000_000 }

  def thresholds(encumbrance: 3, box_limit: 8, coin_limit: 10_000, repair_timer: 600)
    described_class.thresholds(encumbrance: encumbrance, box_limit: box_limit,
                               coin_limit: coin_limit, repair_timer: repair_timer)
  end

  def quiet
    { burden_high: 0, boxes_at_limit: 0, coin_on_hand: 0, repair_timer: 0 }
  end

  def evaluate(observations, limits: thresholds, last_fired: {})
    described_class.evaluate(observations: quiet.merge(observations), thresholds: limits,
                             last_fired: last_fired, now: now)
  end

  describe "the constants the user set" do
    it "gives each town task 1800 seconds" do
      expect(described_class::TASK_TIMEOUT).to eq(1800)
    end

    it "stops on the second consecutive failure of one task" do
      expect(described_class::MAX_TASK_FAILURES).to eq(2)
    end
  end

  describe ".thresholds" do
    it "applies the defaults for the three uc_settings values" do
      limits = described_class.thresholds(encumbrance: nil, box_limit: nil, coin_limit: nil, repair_timer: nil)

      expect(limits).to eq(burden_high: described_class::DEFAULT_ENCUMBRANCE,
                           boxes_at_limit: described_class::DEFAULT_BOX_LIMIT,
                           coin_on_hand: described_class::DEFAULT_COIN_LIMIT,
                           repair_timer: nil)
    end

    # nil means the character has no repair timer, exactly as crossing-repair
    # reads it. A default would invent repairs nobody asked for.
    it "gives repair_timer no default" do
      expect(thresholds(repair_timer: nil)[:repair_timer]).to be_nil
    end
  end

  describe ".evaluate" do
    it "fires nothing when every value is under its threshold" do
      result = evaluate({})

      expect([result.fired, result.cooling, result.tasks]).to eq([[], [], []])
    end

    it "fires at the threshold, not only above it" do
      expect(evaluate({ burden_high: 3 }).fired).to eq([:burden_high])
    end

    it "maps burden_high to sell-loot" do
      expect(evaluate({ burden_high: 5 }).tasks).to eq(["sell-loot"])
    end

    it "maps boxes_at_limit to pick, then sell-loot" do
      expect(evaluate({ boxes_at_limit: 8 }).tasks).to eq(["pick", "sell-loot"])
    end

    it "maps coin_on_hand to sell-loot, because sell-loot deposits" do
      expect(evaluate({ coin_on_hand: 25_000 }).tasks).to eq(["sell-loot"])
    end

    it "maps repair_timer to crossing-repair" do
      expect(evaluate({ repair_timer: 600 }).tasks).to eq(["crossing-repair"])
    end

    it "runs each task once and in pick, sell-loot, crossing-repair order" do
      result = evaluate({ burden_high: 9, boxes_at_limit: 9, coin_on_hand: 99_999, repair_timer: 9999 })

      expect(result.fired).to eq([:burden_high, :boxes_at_limit, :coin_on_hand, :repair_timer])
      expect(result.tasks).to eq(["pick", "sell-loot", "crossing-repair"])
    end

    # A failed probe is not evidence that a trip is due.
    it "never fires on a nil observation" do
      result = described_class.evaluate(observations: { burden_high: nil }, thresholds: thresholds,
                                        last_fired: {}, now: now)

      expect(result.fired).to be_empty
    end

    it "never fires repair_timer when the character has no repair timer" do
      expect(evaluate({ repair_timer: 99_999 }, limits: thresholds(repair_timer: nil)).fired).to be_empty
    end

    it "holds a due trigger that fired inside its cooldown, and reports it as cooling" do
      result = evaluate({ burden_high: 5 }, last_fired: { burden_high: now - 60 })

      expect(result.fired).to be_empty
      expect(result.cooling).to eq([:burden_high])
      expect(result.tasks).to be_empty
    end

    it "fires again once the cooldown has passed" do
      result = evaluate({ burden_high: 5 }, last_fired: { burden_high: now - (15 * 60) })

      expect(result.fired).to eq([:burden_high])
    end

    it "keeps a cooling trigger from blocking a different one" do
      result = evaluate({ burden_high: 5, repair_timer: 700 }, last_fired: { burden_high: now - 60 })

      expect(result.fired).to eq([:repair_timer])
      expect(result.tasks).to eq(["crossing-repair"])
    end

    # crossing-repair can exit cleanly without resetting its timestamp. The
    # interval as a cooldown keeps that from costing a trip after every stint.
    it "uses the repair interval as the repair_timer cooldown" do
      held = evaluate({ repair_timer: 700 }, last_fired: { repair_timer: now - 599 })
      released = evaluate({ repair_timer: 700 }, last_fired: { repair_timer: now - 600 })

      expect(held.cooling).to eq([:repair_timer])
      expect(released.fired).to eq([:repair_timer])
    end
  end

  describe ".order_tasks" do
    it "puts an unknown task last rather than dropping it" do
      expect(described_class.order_tasks(["study-art", "crossing-repair", "pick"]))
        .to eq(["pick", "crossing-repair", "study-art"])
    end
  end

  describe "task failures" do
    it "counts consecutive failures per task" do
      failures = described_class.record_task({}, "sell-loot", false)
      failures = described_class.record_task(failures, "sell-loot", false)

      expect(failures).to eq("sell-loot" => 2)
    end

    it "resets a task's count when that task succeeds" do
      failures = described_class.record_task({ "sell-loot" => 1 }, "sell-loot", true)

      expect(failures).to eq("sell-loot" => 0)
    end

    it "does not reset one task's count when a different task succeeds" do
      failures = described_class.record_task({ "sell-loot" => 1 }, "pick", true)

      expect(failures["sell-loot"]).to eq(1)
    end

    it "returns a new Hash and leaves the old one alone" do
      original = { "pick" => 1 }
      described_class.record_task(original, "pick", false)

      expect(original).to eq("pick" => 1)
    end

    it "continues after one failure" do
      expect(described_class.failure_stop("sell-loot" => 1)).to be_nil
    end

    it "stops on the second failure in a row and names the task" do
      expect(described_class.failure_stop("pick" => 0, "sell-loot" => 2)).to eq("sell-loot")
    end
  end
end
