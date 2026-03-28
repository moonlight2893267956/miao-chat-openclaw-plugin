import { createGatewayClient } from "./src/gateway-client.js";
import { resolvePluginConfig } from "./src/config.js";

const plugin = {
  id: "openclaw-miao-gateway",
  name: "Miao Gateway",
  description: "Miao Chat gateway connector plugin",
  kind: "tools",
  register(api) {
    const config = resolvePluginConfig(api.pluginConfig ?? {});
    for (const warning of config.configWarnings ?? []) {
      api.logger.warn(`miao-gateway: config warning: ${warning}`);
    }
    if (!config.enabled) {
      api.logger.info("miao-gateway: disabled by config");
      api.registerService({ id: "openclaw-miao-gateway", start: () => {}, stop: () => {} });
      return;
    }
    if (!config.wsUrl || !config.channelId) {
      api.logger.warn("miao-gateway: wsUrl/channelId missing, plugin idle");
      api.registerService({ id: "openclaw-miao-gateway", start: () => {}, stop: () => {} });
      return;
    }

    const client = createGatewayClient({ api, config });
    api.registerService({
      id: "openclaw-miao-gateway",
      start: () => client.start(),
      stop: () => client.stop(),
    });
  },
};

export default plugin;
