require "test_helper"

class FeeServiceTest < ActiveSupport::TestCase
  # ── Regression table — flat 2% withdrawal fee, 10 HTG floor, no cap ──────
  WITHDRAW_TABLE = {
    0       => 0,
    100     => 10,     # 2.00 raw -> floor
    499     => 10,     # 9.98 raw -> floor
    500     => 10,     # exactly at the floor break-even
    600     => 12,     # 2% clears the floor
    2_000   => 40,
    5_000   => 100,
    15_000  => 300,
    50_000  => 1_000,  # unverified withdrawal ceiling
    100_000 => 2_000   # BonID-verified ceiling (2x limit)
  }.freeze

  test "withdraw_fee is a flat 2% above the floor" do
    WITHDRAW_TABLE.each do |amount, expected|
      assert_equal BigDecimal(expected.to_s), FeeService.withdraw_fee(amount),
                   "withdraw_fee(#{amount}) should be #{expected} HTG"
    end
  end

  test "withdraw_fee returns a BigDecimal rounded to 2 places" do
    fee = FeeService.withdraw_fee(1_234)
    assert_kind_of BigDecimal, fee
    assert_equal fee.round(2), fee
  end

  test "withdraw_fee is monotonically non-decreasing" do
    prev = BigDecimal("-1")
    (0..120_000).step(250).each do |amount|
      fee = FeeService.withdraw_fee(amount)
      assert fee >= prev, "fee dropped at #{amount} HTG (#{fee} < #{prev})"
      prev = fee
    end
  end

  # ── The property the flat schedule exists to guarantee ──────────────────
  # A flat rate cannot be gamed by splitting: chunks >= 500 HTG each pay
  # exactly 2% (sum == single fee); chunks below 500 hit the floor, so
  # splitting small only ever costs MORE. Never cheaper.
  test "splitting a withdrawal never reduces the total fee" do
    [600, 5_000, 10_000, 50_000].each do |total|
      [2, 5, 10, 25].each do |parts|
        next unless (total % parts).zero?
        chunk     = total / parts
        split_sum = parts * FeeService.withdraw_fee(chunk)
        single    = FeeService.withdraw_fee(total)
        assert split_sum >= single,
               "splitting #{total} into #{parts}x#{chunk} cost #{split_sum} < #{single} (single)"
      end
    end
  end

  # ── Floor ───────────────────────────────────────────────────────────────
  test "withdraw_fee applies the 10 HTG floor below 500 HTG" do
    assert_equal BigDecimal("10"), FeeService.withdraw_fee(100)
    assert_equal BigDecimal("10"), FeeService.withdraw_fee(499)
    assert_equal BigDecimal("10"), FeeService.withdraw_fee(500)  # break-even
  end

  test "withdraw_fee charges the real 2% once it exceeds the floor" do
    assert_equal BigDecimal("12"), FeeService.withdraw_fee(600)
    assert_equal BigDecimal("20"), FeeService.withdraw_fee(1_000)
  end

  # ── No cap ──────────────────────────────────────────────────────────────
  test "withdraw_fee has no maximum cap" do
    # The old flat schedule capped the fee at 2,500 HTG; this one does not.
    fee = FeeService.withdraw_fee(200_000)
    assert_equal BigDecimal("4000"), fee
    assert fee > BigDecimal("2500"), "fee must be able to exceed the old 2,500 cap"
  end

  # ── Degenerate inputs ───────────────────────────────────────────────────
  test "withdraw_fee is zero for zero and negative amounts" do
    assert_equal BigDecimal("0"), FeeService.withdraw_fee(0)
    assert_equal BigDecimal("0"), FeeService.withdraw_fee(-5_000)
  end

  test "withdraw_fee accepts integers, floats, strings and BigDecimals" do
    assert_equal BigDecimal("100"), FeeService.withdraw_fee(5_000)
    assert_equal BigDecimal("100"), FeeService.withdraw_fee(5_000.0)
    assert_equal BigDecimal("100"), FeeService.withdraw_fee("5000")
    assert_equal BigDecimal("100"), FeeService.withdraw_fee(BigDecimal("5000"))
  end

  # ── instant_fee / standard_fee delegate to the one schedule ─────────────
  test "instant_fee and standard_fee both delegate to withdraw_fee" do
    [100, 5_000, 50_000].each do |amount|
      expected = FeeService.withdraw_fee(amount)
      assert_equal expected, FeeService.instant_fee(amount)
      assert_equal expected, FeeService.standard_fee(amount)
    end
  end

  # ── Generic marginal calculator (kept for a future decreasing schedule) ──
  test "marginal_fee sums per-bracket slices" do
    tiers = [
      { upto: BigDecimal("100"), rate: BigDecimal("0.10") },
      { upto: nil,               rate: BigDecimal("0.20") }
    ]
    # 100 * 10% + 50 * 20% = 10 + 10
    assert_equal BigDecimal("20"), FeeService.marginal_fee(150, tiers)
    # entirely within bracket 1
    assert_equal BigDecimal("5"), FeeService.marginal_fee(50, tiers)
  end

  test "marginal_fee handles a split-safe decreasing schedule" do
    # 2.0% up to 15k, 1.5% above — the documented drop-in alternative.
    decreasing = [
      { upto: BigDecimal("15000"), rate: BigDecimal("0.02") },
      { upto: nil,                 rate: BigDecimal("0.015") }
    ]
    # 50,000 -> 15,000*2% + 35,000*1.5% = 300 + 525
    assert_equal BigDecimal("825"), FeeService.marginal_fee(50_000, decreasing)
    # splitting can't beat it: a 50k chunk re-enters the pricier 2% bottom
    split = 2 * FeeService.marginal_fee(25_000, decreasing)
    assert split >= FeeService.marginal_fee(50_000, decreasing)
  end

  test "marginal_fee applies the floor argument" do
    tiers = [{ upto: nil, rate: BigDecimal("0.01") }]
    assert_equal BigDecimal("25"), FeeService.marginal_fee(100, tiers, floor: BigDecimal("25"))
    assert_equal BigDecimal("0"),  FeeService.marginal_fee(0, tiers, floor: BigDecimal("25"))
  end
end
