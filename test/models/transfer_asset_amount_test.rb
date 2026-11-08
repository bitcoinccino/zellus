require "test_helper"

class TransferAssetAmountTest < ActiveSupport::TestCase
  test "USD from HTG settles in whole cents" do
    # The real case: 136 HTG at 135.50 used to move 1.00369 USD.
    assert_equal BigDecimal("1.00"), Transfer.asset_amount_from_htg(136, 135.5, "usd")
    # 676 HTG used to move 4.98893 and leave 0.00369 behind.
    assert_equal BigDecimal("4.99"), Transfer.asset_amount_from_htg(676, 135.5, "usd")
  end

  test "USD rounds half up" do
    # 0.005 USD exactly → 0.01
    assert_equal BigDecimal("0.01"), Transfer.asset_amount_from_htg(BigDecimal("0.6775"), 135.5, "usd")
  end

  test "other assets keep their precision" do
    assert_equal 0.00001053, Transfer.asset_amount_from_htg(136, 12_915_000, "wbtc")
  end
end
