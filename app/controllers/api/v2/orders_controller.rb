# frozen_string_literal: true

class Api::V2::OrdersController < Api::V2::BaseController
  include Events

  before_action(only: [:create]) { doorkeeper_authorize! :create_purchases }
  before_action :normalize_line_items, only: :create

  def create
    permitted = permitted_order_params
    permitted[:email] = current_resource_owner.email if permitted[:email].blank?
    order_params = permitted.merge!(
      browser_guid: SecureRandom.uuid,
      session_id: request.request_id,
      ip_address: request.remote_ip,
      is_mobile: false
    ).to_h

    order, purchase_responses, offer_codes = Order::CreateService.new(
      buyer: current_resource_owner,
      params: order_params
    ).perform

    charge_responses = Order::ChargeService.new(order:, params: order_params).perform

    purchase_responses.merge!(charge_responses)

    order.purchases.each { create_purchase_event_and_recommendation_info(_1) }
    order.send_charge_receipts unless purchase_responses.any? { |_k, v| v[:requires_card_action] || v[:requires_card_setup] }

    decorated_responses = decorate_action_required_responses(purchase_responses, order_params[:line_items])

    render json: { success: true, line_items: decorated_responses, offer_codes: }
  end

  private
    def normalize_line_items
      if params[:line_items].is_a?(ActionController::Parameters)
        params[:line_items] = params[:line_items].values
      end
    end

    def permitted_order_params
      params.permit(
        :friend, :locale, :plugins, :save_card, :card_data_handling_mode, :card_data_handling_error,
        :card_country, :card_country_source, :wallet_type, :cc_zipcode, :vat_id, :email, :tax_country_election,
        :save_shipping_address, :card_expiry_month, :card_expiry_year, :stripe_status, :visual,
        :billing_agreement_id, :paypal_order_id, :stripe_payment_method_id, :stripe_customer_id, :stripe_setup_intent_id, :stripe_error,
        :braintree_transient_customer_store_key, :braintree_device_data, :use_existing_card, :paymentToken,
        :url_parameters, :is_gift, :giftee_email, :giftee_id, :gift_note, :referrer,
        purchase: [:full_name, :street_address, :city, :state, :zip_code, :country],
        line_items: [:uid, :permalink, :perceived_price_cents, :price_range, :discount_code, :is_preorder, :quantity, :call_start_time,
                     :was_product_recommended, :recommended_by, :referrer, :is_rental, :is_multi_buy,
                     :was_discover_fee_charged, :price_cents, :tax_cents, :gumroad_tax_cents, :shipping_cents, :price_id, :affiliate_id, :url_parameters, :is_purchasing_power_parity_discounted,
                     :recommender_model_name, :tip_cents, :pay_in_installments, :force_new_subscription,
                     custom_fields: [:id, :value], variants: [], perceived_free_trial_duration: [:unit, :amount], accepted_offer: [:id, :original_variant_id, :original_product_id],
                     bundle_products: [:product_id, :variant_id, :quantity, custom_fields: [:id, :value]]])
    end

    def create_purchase_event_and_recommendation_info(purchase)
      create_purchase_event(purchase)
      purchase.handle_recommended_purchase if purchase.was_product_recommended
    end

    def decorate_action_required_responses(responses, line_items)
      permalink_by_uid = Array(line_items).each_with_object({}) { |li, acc| acc[li[:uid]] = li[:permalink] }

      responses.each_with_object({}) do |(uid, response), result|
        if response[:requires_card_action] || response[:requires_card_setup]
          permalink = permalink_by_uid[uid]
          product = permalink && Link.find_by(unique_permalink: permalink)
          confirmation_url = product && "#{product.user.subdomain_with_protocol}/l/#{product.unique_permalink}"
          result[uid] = response.merge(requires_action: true, confirmation_url:)
        else
          result[uid] = response
        end
      end
    end
end
