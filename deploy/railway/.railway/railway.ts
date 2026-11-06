// Railway infrastructure for decidim.vocdoni.dev (project `decidim-vocdoni`).
// Variables are unmanaged: they hold secrets and are set with `railway
// variable set` (names in ../README.md). `web` and `worker` build the same
// Dockerfile; only `web` runs the db:migrate release step and takes traffic.
import { bucket, defineRailway, postgres, project, redis, service, volume } from "railway/iac";

export default defineRailway(() => {
  const Redis = redis("Redis", { region: "europe-west4-drams3a" });
  Redis.deploy = { startCommand: "/bin/sh -c \"rm -rf $RAILWAY_VOLUME_MOUNT_PATH/lost+found/ && exec docker-entrypoint.sh redis-server --requirepass $REDIS_PASSWORD --save 60 1 --dir $RAILWAY_VOLUME_MOUNT_PATH\"" };
  Redis.networking = { privateNetworkEndpoint: "redis" };
  const Postgres = postgres("Postgres", { region: "europe-west4-drams3a" });
  Postgres.networking = { privateNetworkEndpoint: "postgres" };
  const redisVolume = volume("redis-volume", { alerts: { usage: { "100": {}, "80": {}, "95": {} } }, allowOnlineResize: true, region: "europe-west4-drams3a", sizeMB: 50000 });
  const postgresVolume = volume("postgres-volume", { alerts: { usage: { "100": {}, "80": {}, "95": {} } }, allowOnlineResize: true, region: "europe-west4-drams3a", sizeMB: 50000 });
  const uploads = bucket("uploads", { region: "ams" });
  const worker = service("worker", {
    build: { buildEnvironment: "V3", builder: "DOCKERFILE", dockerfilePath: "Dockerfile" },
    deploy: {
      startCommand: "bundle exec sidekiq -C config/sidekiq.yml",
      restartPolicyType: "ALWAYS",
    },
    replicas: { "europe-west4-drams3a": 1 },
  });
  const web = service("web", {
    build: { buildEnvironment: "V3", builder: "DOCKERFILE", dockerfilePath: "Dockerfile" },
    deploy: {
      startCommand: "bundle exec puma -C config/puma.rb",
      preDeployCommand: ["bin/release"],
      healthcheckPath: "/up",
      healthcheckTimeout: 300,
      restartPolicyType: "ON_FAILURE",
      restartPolicyMaxRetries: 10,
    },
    domains: ["decidim.vocdoni.dev"],
    replicas: { "europe-west4-drams3a": 1 },
  });

  return project("decidim-vocdoni", {
    variables: { managed: false },
    resources: [worker, Redis, web, Postgres, redisVolume, postgresVolume, uploads],
  });
});
