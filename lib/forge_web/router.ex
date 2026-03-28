defmodule ForgeWeb.Router do
  use ForgeWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ForgeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ForgeWeb do
    pipe_through :browser

    live "/", HomeLive
    live "/project/:path", ProjectLive
    live "/session/:id", DashboardLive
  end

  # MCP API — supplementary tools for agents
  scope "/api/mcp", ForgeWeb do
    pipe_through :api

    get "/tools", ApiController, :tools
    get "/get_project_info", ApiController, :get_project_info
    post "/update_context", ApiController, :update_context
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:forge, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ForgeWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
