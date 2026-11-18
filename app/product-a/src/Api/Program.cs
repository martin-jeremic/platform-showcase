// ProductA.Api - STUB. The business code is gone; what is left is the platform contract every
// service on the platform implements (see app/README.md):
//
//   * configuration from environment variables: one PLAIN-JSON variable per config group, bound
//     to options and validated at start-up, so a bad value fails the pod, not the first request;
//   * /health/live (the process is up, no dependencies) vs /health/ready (dependencies reachable);
//   * JSON logs, one object per line, on stdout; no files, no sinks inside the pod;
//   * SIGTERM drain: stop accepting, finish in-flight requests, exit inside the grace period;
//   * a verb entrypoint (--migrate / --verify / --seed), so the migration Job runs THIS image with
//     `args:` only. The chiseled runtime has no shell, so there is nothing to wrap the call in.

using System.ComponentModel.DataAnnotations;
using System.Data.Common;
using System.Diagnostics;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Options;

// A verb run must not also feed its arguments to the command-line configuration provider:
// `--migrate --plan` would otherwise read as the key "migrate" with the value "--plan".
var verb = args.FirstOrDefault(a => a is "--migrate" or "--verify" or "--seed");
var builder = WebApplication.CreateBuilder(verb is null ? args : []);

// ---- Logging: JSON lines on stdout ----------------------------------------------------------
// The node's log agent ships stdout; the pod never writes a log file (the root filesystem is
// read-only anyway). UTC timestamps, so lines from different nodes sort without guessing zones.
builder.Logging.ClearProviders();
builder.Logging.AddJsonConsole(o =>
{
    o.UseUtcTimestamp = true;
    o.TimestampFormat = "yyyy-MM-ddTHH:mm:ss.fffZ";
    o.IncludeScopes = true;
    o.JsonWriterOptions = new JsonWriterOptions { Indented = false };
});

// ---- Configuration: one plain-JSON environment variable per group ---------------------------
// Non-sensitive groups come from the chart's ConfigMap, secret-bearing ones from the Secret that
// the Key Vault CSI driver syncs. There is no appsettings.Production.json in the image: what the
// pod runs with is exactly what `kubectl get cm,secret` shows.
// A group's secret half arrives as a separate Section__Key variable (Identity__ClientSecret,
// Broker__Password) and .NET configuration merges it into the same section, so the ConfigMap
// never carries a secret and the vault never carries plain configuration.
EnvironmentJson.AddGroup(builder.Configuration, "API", ApiOptions.Section);
EnvironmentJson.AddGroup(builder.Configuration, "DATABASE", DatabaseOptions.Section);
EnvironmentJson.AddGroup(builder.Configuration, "MODULE", ModuleClientOptions.Section);
// Bound by the real service's identity, broker and storage options; the stub validates only the
// three groups above.
EnvironmentJson.AddGroup(builder.Configuration, "IDENTITY", "Identity");
EnvironmentJson.AddGroup(builder.Configuration, "BROKER", "Broker");
EnvironmentJson.AddGroup(builder.Configuration, "BLOBSTORAGE", "BlobStorage");

builder.Services.AddOptions<ApiOptions>()
    .BindConfiguration(ApiOptions.Section).ValidateDataAnnotations().ValidateOnStart();
builder.Services.AddOptions<DatabaseOptions>()
    .BindConfiguration(DatabaseOptions.Section).ValidateDataAnnotations().ValidateOnStart();
builder.Services.AddOptions<ModuleClientOptions>()
    .BindConfiguration(ModuleClientOptions.Section).ValidateDataAnnotations().ValidateOnStart();

// ---- Health: live vs ready -------------------------------------------------------------------
// Liveness must not depend on anything outside the process: a database outage that fails
// liveness restarts every replica at once and turns a dependency blip into an outage.
// Readiness is where dependencies belong: a pod that cannot reach its database leaves the
// Service endpoints and stops receiving traffic, and comes back by itself.
builder.Services.AddHealthChecks()
    .AddCheck("self", () => HealthCheckResult.Healthy(), tags: ["live"])
    .AddCheck<DatabaseReachableCheck>("database", tags: ["ready"]);

// ---- Graceful shutdown -----------------------------------------------------------------------
// The chart gives the pod terminationGracePeriodSeconds: 30 and a 5 s preStop sleep (so the
// endpoint removal reaches every node before SIGTERM arrives). Kestrel then stops accepting and
// drains in-flight requests for up to 20 s: 5 + 20 stays inside 30, so the kubelet never has to
// SIGKILL a request half-way.
builder.Services.Configure<HostOptions>(o => o.ShutdownTimeout = TimeSpan.FromSeconds(20));

var app = builder.Build();

if (verb is not null)
{
    // Same image, same configuration binding, no web host: the migration Job's whole contract.
    return await MigrationVerbs.RunAsync(app.Services, verb, args);
}

// Request log on the same JSON stream. The query string is never logged (it can carry an OIDC
// ?code= or a signed URL); successful kubelet probes are dropped, failing ones are kept.
var requestLog = app.Services.GetRequiredService<ILoggerFactory>().CreateLogger("Http.Request");
app.Use(async (ctx, next) =>
{
    var started = Stopwatch.GetTimestamp();
    await next(ctx);
    var status = ctx.Response.StatusCode;
    if (status < 400 && ctx.Request.Headers.UserAgent.ToString().StartsWith("kube-probe/", StringComparison.Ordinal))
    {
        return;
    }
    requestLog.LogInformation(
        "HTTP {HttpMethod} {HttpPath} responded {HttpStatus} in {DurationMs} ms",
        ctx.Request.Method, ctx.Request.Path.Value, status,
        (long)Stopwatch.GetElapsedTime(started).TotalMilliseconds);
});

// Probe paths are pod-local: the kubelet calls the container port directly and never passes
// through the gateway's /admin/api -> /api prefix rewrite.
app.MapHealthChecks("/health/live", new HealthCheckOptions { Predicate = r => r.Tags.Contains("live") });
app.MapHealthChecks("/health/ready", new HealthCheckOptions { Predicate = r => r.Tags.Contains("ready") });

app.MapGet("/api/info", (IOptions<ApiOptions> api) => Results.Ok(new
{
    api.Value.Name,
    Version = typeof(ApiOptions).Assembly.GetName().Version?.ToString(),
}));

await app.RunAsync();
return 0;

/// <summary>Binds one environment variable holding plain JSON onto a configuration section.</summary>
static class EnvironmentJson
{
    public static void AddGroup(IConfigurationBuilder configuration, string variable, string section)
    {
        var raw = Environment.GetEnvironmentVariable(variable)?.Trim();
        if (string.IsNullOrEmpty(raw))
        {
            // Not set: the options keep their defaults and ValidateOnStart decides whether that
            // is acceptable. Required groups fail the start-up with the option's own message.
            return;
        }

        // Plain JSON only. Values used to travel Base64-encoded, and a binder that "helpfully"
        // decoded both forms let encoded blobs creep back in unnoticed. Refusing anything that is
        // not JSON turns that into a loud crash-loop that names the variable. The value itself is
        // never logged: DATABASE carries a password.
        if (raw[0] is not ('{' or '['))
        {
            throw new InvalidOperationException(
                $"Environment variable '{variable}' is not JSON. Store the group as plain JSON, not Base64.");
        }

        var wrapped = $"{{\"{section}\":{raw}}}";
        configuration.AddJsonStream(new MemoryStream(Encoding.UTF8.GetBytes(wrapped)));
    }
}

sealed class ApiOptions
{
    public const string Section = "Api";

    [Required]
    public string Name { get; set; } = "";

    [Required]
    public string Environment { get; set; } = "";
}

sealed class DatabaseOptions
{
    public const string Section = "Database";

    [Required]
    public string PostgresConnection { get; set; } = "";
}

sealed class ModuleClientOptions
{
    public const string Section = "Module";

    // Deliberately no default. The real client defaulted to http://localhost:8000 (the developer's
    // standalone run), so an unset value did not fail: it called localhost INSIDE the pod and every
    // request died with connection-refused. Required + validated at start-up is the honest version.
    [Required, Url]
    public string BaseUrl { get; set; } = "";
}

/// <summary>
/// Readiness: can this pod reach its database? The real service ran a query through its DbContext;
/// the stub only opens a TCP connection, because it carries no database driver package.
/// </summary>
sealed class DatabaseReachableCheck(IOptions<DatabaseOptions> options) : IHealthCheck
{
    public async Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        var csb = new DbConnectionStringBuilder { ConnectionString = options.Value.PostgresConnection };
        var host = csb.TryGetValue("Host", out var h) ? h?.ToString() : null;
        var port = csb.TryGetValue("Port", out var p) && int.TryParse(p?.ToString(), out var n) ? n : 5432;
        if (string.IsNullOrEmpty(host))
        {
            return HealthCheckResult.Unhealthy("DATABASE has no Host");
        }

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(2));
        try
        {
            using var tcp = new TcpClient();
            await tcp.ConnectAsync(host, port, timeout.Token);
            return HealthCheckResult.Healthy();
        }
        catch (Exception ex) when (ex is SocketException or OperationCanceledException)
        {
            return HealthCheckResult.Unhealthy($"database {host}:{port} unreachable", ex);
        }
    }
}

/// <summary>
/// The verbs the product-a-db Job calls. Exit code is the Job's result: 0 = Complete, anything
/// else = Failed (backoffLimit 0, so a failure is investigated, never retried blindly).
/// </summary>
static class MigrationVerbs
{
    public static async Task<int> RunAsync(IServiceProvider services, string verb, string[] args)
    {
        var log = services.GetRequiredService<ILoggerFactory>().CreateLogger("Migrations");
        var plan = args.Contains("--plan");

        DatabaseOptions database;
        try
        {
            // Resolving the options runs the data-annotation validation: an empty DATABASE fails
            // here with the option's own message, not later as a confusing driver error.
            database = services.GetRequiredService<IOptions<DatabaseOptions>>().Value;
        }
        catch (OptionsValidationException ex)
        {
            log.LogError("Configuration invalid: {Failures}", string.Join("; ", ex.Failures));
            return 2;
        }

        log.LogInformation("Verb {Verb} started (plan only: {Plan})", verb, plan);

        // Stub: the real verbs applied EF Core migrations per schema (platform, then each tenant),
        // verified the migration history against the assembly, or ran convergent seed steps.
        _ = database;
        await Task.Delay(TimeSpan.FromMilliseconds(10));

        log.LogInformation("Verb {Verb} finished", verb);
        return 0;
    }
}
