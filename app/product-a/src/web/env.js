// Runtime configuration for the SPA. This default is deliberately empty: one image serves every
// environment, and a cluster mounts the chart's ConfigMap over this file (subPath env.js).
// The app reads window.__env at start-up and refuses to boot without its required keys.
window.__env = {};
