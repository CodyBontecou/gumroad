# `POST /api/v2/orders`

Programmatic, OAuth-authenticated guest checkout. Mirrors the order-creation path that powers `POST /orders` (the web checkout) but skips browser-only gates (CSRF, reCAPTCHA, `_gumroad_guid` cookie). Use for CLI buyers and agent-driven purchases.

## Authentication

OAuth bearer token with the `create_purchases` scope (or the `account` superuser scope, per `Api::V2::BaseController`). The token's resource owner is recorded as the buyer, and their email is used for the receipt unless overridden in the request body.

```
Authorization: Bearer <token>
```

## Request

```http
POST /api/v2/orders
Content-Type: application/json

{
  "email": "buyer@example.com",
  "stripe_payment_method_id": "pm_xxx",
  "stripe_customer_id": "cus_xxx",
  "line_items": [{
    "uid": "li-0",
    "permalink": "abc123",
    "perceived_price_cents": 500,
    "quantity": 1
  }]
}
```

`email` is optional — defaults to the OAuth user's email. The Stripe payment method must be attached to Gumroad's platform Stripe account; tokenize against `STRIPE_PUBLIC_KEY` before calling. Other line-item fields supported by `OrdersController#permitted_order_params` (variants, `discount_code`, `affiliate_id`, `tip_cents`, `custom_fields`, `bundle_products`, `is_gift`, etc.) are accepted unchanged.

## Response

Each line item is keyed by its `uid`. HTTP status is always 200; per-item failures surface as `success: false` on the line item.

### Success

```json
{
  "success": true,
  "line_items": {
    "li-0": {
      "success": true,
      "name": "Product Name",
      "price": "$5",
      "content_url": "https://...",
      "redirect_token": "..."
    }
  },
  "offer_codes": []
}
```

### Card declined / validation error

```json
{
  "success": true,
  "line_items": {
    "li-0": {
      "success": false,
      "error_message": "Your card was declined.",
      "error_code": "card_declined"
    }
  }
}
```

### 3D Secure required

```json
{
  "success": true,
  "line_items": {
    "li-0": {
      "success": true,
      "requires_action": true,
      "requires_card_action": true,
      "client_secret": "pi_xxx_secret_yyy",
      "confirmation_url": "https://seller.gumroad.com/l/abc123",
      "order": {
        "id": "<secure-confirm-id>",
        "stripe_connect_account_id": null
      }
    }
  }
}
```

`confirmation_url` points to the product's web checkout — open it in a browser to complete the SCA challenge. Receipt delivery is deferred until the challenge succeeds.

## Rate limit

10 POSTs per IP per minute (`config/initializers/rack_attack.rb`). Replaces the reCAPTCHA gate that protects the legacy web endpoint.

## Out of scope

- Native Stripe Link as a `payment_method_type` — `payment_method_types` is hardcoded to `["card"]` in `stripe_charge_processor.rb`. A Stripe-Link-issued payment method (e.g. from `stripe/link-cli`) lives on Stripe Link's platform account and cannot be cloned onto a seller's connected account by the existing flow in `stripe_chargeable_payment_method.rb#prepare_for_direct_charge`. Tokenize a card against Gumroad's publishable key instead.
- Confirming a 3DS-pending order via the API. Use the existing `POST /orders/:id/confirm` endpoint after the buyer completes SCA in the browser.
