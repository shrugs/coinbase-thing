require 'dotenv/load'
require 'bigdecimal'
require 'sinatra'
require 'coinbase/exchange'
require 'pry'

# monkey patch BigDecimal
# obviously we wouldn't do this normally
class BigDecimal
	old_to_s = instance_method :to_s

	define_method :to_s do |param='F'|
		old_to_s.bind(self).(param)
	end
end

class InvalidParams < StandardError
end

# defining constants for this is probably overkill
SIDE_KEY = 'action'
# ^ I prefer to reference this as a side rather than an action
BASE_CURRENCY_KEY = 'base_currency'
QUOTE_CURRENCY_KEY = 'quote_currency'
AMOUNT_KEY = 'amount'

# We want clean exception handling, so stop sinatra from trying to help us.
set :show_exceptions, false

# GDAX Client and method calls
def gdax
	# don't need to authenticate to get orderbook
	@gdax ||= Coinbase::Exchange::Client.new()
end

def products_info
  @products_info ||= gdax.products.group_by(&:id)
end

def product_info(product_id)
  products_info[product_id]
end

def valid_product_ids
	products_info.keys
end

def is_valid_product_id(product_id)
	valid_product_ids.include?(product_id)
end

def build_product_id(base, quote)
	"#{base}-#{quote}"
end

# Returns the orderbook, inverting it if necessary
def get_orderbook(product_id, is_inverted = false)
	gdax_book = gdax.orderbook(level: 2, product_id: product_id)

  orderbook = {
    bids: format_aggregated_orders(gdax_book['bids']),
    asks: format_aggregated_orders(gdax_book['asks'])
  }

	if is_inverted
		return invert_book(orderbook)
  end

  return orderbook
end

def invert_book(orderbook)
  {
    bids: invert_orders(orderbook[:asks]).sort_by { |o| o[:price] }.reverse,
    asks: invert_orders(orderbook[:bids]).sort_by { |o| o[:price] }
  }
end

# if this is a sell, we look at bids
# if this is a buy, we look at asks
def orders_for_side(side)
	side === :sell ? :bids : :asks
end

def match_order(orders, amount)
	amount_needed = amount
	consumed_orders = []
	orders.each do |order|
		if order[:size] >= amount_needed
			consumed_orders << {
				size: amount_needed,
				price: order[:price]
			}
			break
		else
			consumed_orders << order
			amount_needed -= order[:size]
		end
	end

	# avg = sum(price * size) / sum(price)
	total_amount_filled = consumed_orders
		.map { |o| o[:size] }
		.reduce(&:+)
	average_price = consumed_orders
		.map { |o| o[:size] * o[:price] }
		.reduce(&:+)
		.div(total_amount_filled, 0)

	return total_amount_filled, average_price
end

# Method Handler

post '/quote' do
	side, base, quote, amount, is_inverted = normalize_order(*quote_params)
	product_id = build_product_id(base, quote)
	book = get_orderbook(product_id, is_inverted)

	orders = book[orders_for_side(side)]

	total, price = match_order(orders, amount)

	return do_json({
		total: total,
		price: price,
		currency: is_inverted ? base : quote
	})
end


# Helpers and Stuff

# We allow users to input the quote and base in whichever
#   order they like, but because coinbase only stores orderbooks
#   for a specific derivative, we need to invert/normalize/whatever
#   an order if necessary.
def normalize_order(side, base, quote, amount)
	product_id = build_product_id(base, quote)
	if is_valid_product_id(product_id)
		# nothing to do here
		return side, base, quote, amount, false
	end

	product_id = build_product_id(quote, base)
	if is_valid_product_id(product_id)
		# swap 'em
		return side, quote, base, amount, true
	end

	raise InvalidParams, "Invalid base and/or quote currencies #{base} and #{quote}."
end

# This inverts a set of trades so that the base and quote currencies are swapped
# 5 BTCUSD @ $4k is $20k USDBTC @ 1/4k
# We want to convert the size of the order to the new quote currency as well
def invert_orders(orders)
	orders.map do |order|
		{
			size: order[:size] * order[:price],
			price: 1 / order[:price]
		}
	end
end

def format_aggregated_orders(orders)
	# we don't care about num orders in this case
	orders.map do |(price, size, *rest)|
		{
			price: BigDecimal.new(price),
			size: BigDecimal.new(size)
		}
	end
end

# BYO Param Validation
def quote_params
	begin
		side = params.fetch(SIDE_KEY).to_sym
		base_currency = params.fetch(BASE_CURRENCY_KEY).upcase
		quote_currency = params.fetch(QUOTE_CURRENCY_KEY).upcase
		amount = BigDecimal.new(params.fetch(AMOUNT_KEY))

		if not side == :sell and not side == :buy
			raise InvalidParams, 'side is not one of sell or buy'
		end

		if amount <= 0
			raise InvalidParams, 'amount must be greater than 0. why would you do this'
		end

		return side, base_currency, quote_currency, amount
	rescue KeyError => e
		raise InvalidParams, 'Invalid Params'
	end
end

error do
	do_error(env['sinatra.error'].message)
end

def do_error(message)
	status 400
	headers \
		'Content-Type' => 'appliation/json'
	body ({ message: message }.to_json)
end

def do_json(res)
	status 200
	headers \
		'Content-Type' => 'appliation/json'
	body res.to_json
end
