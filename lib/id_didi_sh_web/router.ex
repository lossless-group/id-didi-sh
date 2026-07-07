defmodule IdDidiShWeb.Router do
  use IdDidiShWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {IdDidiShWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", IdDidiShWeb do
    pipe_through :browser

    get "/", PageController, :home
    # The magic-link landing (emails point here). Two-step on purpose:
    # GET renders a confirm button; only the POST consumes the token —
    # mail-scanner prefetch can't burn a single-use link.
    get "/access", AccessController, :show
    post "/access", AccessController, :redeem
  end

  # The headless API — the contract consumers call from their own UIs.
  scope "/api", IdDidiShWeb do
    pipe_through :api

    post "/magic-links", MagicLinkController, :create
    post "/magic-links/redeem", MagicLinkController, :redeem
    post "/session/refresh", SessionController, :refresh
    delete "/session", SessionController, :delete
    get "/me", MeController, :show
  end

  scope "/.well-known", IdDidiShWeb do
    pipe_through :api

    get "/jwks.json", JWKSController, :show
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:id_didi_sh, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: IdDidiShWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
