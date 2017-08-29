require_relative './app'

describe Sinatra::Application do
  let(:app) { Sinatra::Application }

  context 'gdax stuff' do
    let(:book) { get_orderbook('BTC-USD') }
    let(:inverted_book) { invert_book(book) }

    it 'provides an orderbook' do
      expect(book).to have_key(:bids)
      expect(book).to have_key(:asks)
    end

    it 'validates product ids' do
      expect(is_valid_product_id('BTC-USD')).to be(true)
      expect(is_valid_product_id('USD-BTC')).to be(false)
      expect(is_valid_product_id('')).to be(false)
      expect(is_valid_product_id('banana')).to be(false)
    end

    it 'can invert an orderbook' do
      # the best bid should be the best ask now
      best_ask = book[:asks].first
      expect(inverted_book[:bids].first).to eq({
        size: best_ask[:price] * best_ask[:size],
        price: 1 / best_ask[:price]
      })
    end

  end

  context 'normalize_order' do
    let(:base) { 'BTC' }
    let(:quote) { 'USD' }
    let(:amount) { 1 }
    it 'doesn\'t swap correct order' do
      side, new_base, new_quote, new_amount, is_inverted = normalize_order(
        :buy, base, quote, amount
      )

      expect(side).to be(:buy)
      expect(new_base).to be(base)
      expect(new_quote).to be(quote)
      expect(new_amount).to be(amount)
      expect(is_inverted).to be(false)
    end

    it 'swaps inverted order' do
      side, new_base, new_quote, new_amount, is_inverted = normalize_order(
        :buy, quote, base, amount
      )

      expect(side).to be(:buy)
      expect(new_base).to be(base)
      expect(new_quote).to be(quote)
      expect(new_amount).to be(amount)
      expect(is_inverted).to be(true)
    end
  end
end
