import Config

# Never launch the real native helper during tests. Transport tests start their own
# Helper instances with an explicit fake command; everything else leaves the global
# helper idle in an "unavailable" state.
config :eva_desktop_mac, :helper, :disabled
