# frozen_string_literal: true

require "spec_helper"

describe Api::V2::OrdersController, :vcr do
  before do
    MerchantAccount.find_or_create_by!(user_id: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id) do |ma|
      ma.charge_processor_alive_at = Time.current
    end

    @user = create(:user, email: "buyer@example.com")
    @app = create(:oauth_application, owner: create(:user))
    @action = :create
    @params = { line_items: [] }
  end

  describe "POST 'create'" do
    it "returns 401 when no access token is provided" do
      post @action, params: @params
      expect(response.status).to eq(401)
      expect(response.body.strip).to be_empty
    end

    it "returns 403 when the access token lacks the create_purchases scope" do
      token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
      post @action, params: @params.merge(access_token: token.token)
      expect(response.status).to eq(403)
    end

    context "with a valid create_purchases token" do
      let(:token) { create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "create_purchases") }
      let(:seller) { create(:user) }
      let(:price_cents) { 5_00 }
      let(:product) { create(:product, user: seller, price_cents:) }
      let(:payment_params) { StripePaymentMethodHelper.success.to_stripejs_params }
      let(:single_line_item_params) do
        {
          access_token: token.token,
          line_items: [{
            uid: "unique-id-0",
            permalink: product.unique_permalink,
            perceived_price_cents: price_cents,
            quantity: 1
          }]
        }.merge(payment_params)
      end

      it "creates an order, a charge, and a successful purchase" do
        expect do
          expect do
            expect do
              post @action, params: single_line_item_params

              expect(response.status).to eq(200)
              expect(response.parsed_body["success"]).to be(true)
              expect(response.parsed_body["line_items"]["unique-id-0"]["success"]).to be(true)
            end.to change(Purchase.successful, :count).by(1)
          end.to change(Charge, :count).by(1)
        end.to change(Order, :count).by(1)

        purchase = Purchase.last
        expect(purchase.email).to eq(@user.email)
        expect(purchase.purchaser).to eq(@user)
        expect(purchase.link).to eq(product)
        expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(purchase.charge.id)
      end

      it "uses the explicit email param over the resource owner's email" do
        post @action, params: single_line_item_params.merge(email: "alice@example.com")
        expect(response.parsed_body["line_items"]["unique-id-0"]["success"]).to be(true)
        expect(Purchase.last.email).to eq("alice@example.com")
      end

      it "returns success false on the line item when the card is declined" do
        declined_params = single_line_item_params
          .except(:card_data_handling_mode, :stripe_payment_method_id, :stripe_customer_id)
          .merge(StripePaymentMethodHelper.decline.to_stripejs_params)

        expect do
          post @action, params: declined_params

          expect(response.status).to eq(200)
          expect(response.parsed_body["success"]).to be(true)
          expect(response.parsed_body["line_items"]["unique-id-0"]["success"]).to be(false)
          expect(response.parsed_body["line_items"]["unique-id-0"]["error_message"]).to be_present
        end.not_to change(Purchase.successful, :count)
      end

      it "returns a Product not found error when the permalink does not match any product" do
        post @action, params: single_line_item_params.merge(
          line_items: [single_line_item_params[:line_items].first.merge(permalink: "no-such-permalink")]
        )

        expect(response.parsed_body["line_items"]["unique-id-0"]["success"]).to be(false)
        expect(response.parsed_body["line_items"]["unique-id-0"]["error_message"]).to eq("Product not found")
      end

      it "surfaces a confirmation_url and skips the receipt when 3DS verification is required" do
        sca_params = single_line_item_params
          .except(:card_data_handling_mode, :stripe_payment_method_id, :stripe_customer_id)
          .merge(StripePaymentMethodHelper.success_with_sca.to_stripejs_params)

        post @action, params: sca_params

        line_item = response.parsed_body["line_items"]["unique-id-0"]
        expect(line_item["requires_action"]).to be(true)
        expect(line_item["client_secret"]).to be_present
        expect(line_item["confirmation_url"]).to start_with("http")
        expect(line_item["confirmation_url"]).to include("/l/#{product.unique_permalink}")
        expect(SendChargeReceiptJob.jobs.size).to eq(0)
      end

      it "completes a free product purchase with perceived_price_cents zero" do
        free_product = create(:product, user: seller, price_cents: 0)
        free_params = {
          access_token: token.token,
          line_items: [{
            uid: "unique-id-0",
            permalink: free_product.unique_permalink,
            perceived_price_cents: 0,
            quantity: 1
          }]
        }

        expect do
          post @action, params: free_params

          expect(response.parsed_body["line_items"]["unique-id-0"]["success"]).to be(true)
        end.to change(Purchase.successful, :count).by(1)
      end

      it "marks the resource owner as a CLI user when the request user agent identifies gumroad-cli" do
        request.user_agent = "gumroad-cli/1.0.0"
        expect { post @action, params: single_line_item_params }.to change { @user.reload.has_used_cli? }.from(false).to(true)
      end
    end
  end
end
