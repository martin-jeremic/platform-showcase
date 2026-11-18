# ---------------------------------------------------------------------------
# Argo CD, bootstrap install.
#
# The one component this stack installs INSIDE the cluster, deliberately: Argo CD
# deploys everything else, so it cannot deploy itself the first time. Everything
# downstream (ingress, cert-manager, the applications) stays out of this repo.
#
# ---------------------------------------------------------------------------
# THIS RELEASE IS ADOPTED AT SYNC WAVE 5. THREE THINGS MUST LINE UP.
# ---------------------------------------------------------------------------
# At wave 5 the wrapper chart (platform/charts/argocd, delivered by
# gitops/platform) takes over these same objects and adds the HTTPRoute and the
# OIDC config. Argo CD does not "adopt" a Helm release in the Helm sense -- it
# renders `helm template` and applies the result with server-side apply -- so the
# hand-off works if and only if THE RENDERED OBJECT NAMES MATCH. Hence:
#
#   1. name    = var.argocd_release_name, equal to the descriptor's releaseName and
#                the wrapper's fullnameOverride. With a different name the objects
#                render under two prefixes, and wave 5 stands up a SECOND Argo CD
#                beside this one, both reconciling the same repo.
#   2. version = var.argocd_chart_version, which MUST equal the argo-cd dependency
#                pinned in the wrapper's Chart.yaml. A mismatch makes the hand-off
#                simultaneously an upgrade of the controller performing it.
#   3. values  = a mirror of the wrapper's values, so the wave-5 delta is only what
#                SSO and the route need: the HTTPRoute (new object), argocd-cm
#                (oidc.config, url), argocd-cmd-params-cm (server.rootpath) and
#                argocd-rbac-cm (group mapping). Every container, image, resource,
#                replica count, PDB, spread constraint and Service renders
#                BYTE-IDENTICAL; pods roll once because the ConfigMap checksums
#                change, which is the intended effect of the config change.
#
# Verify the naming claim rather than trusting it: render both sides and diff the
# object names. The ONE expected difference besides the route: this install
# creates argocd-secret and the wrapper does not (configs.secret below).
# ---------------------------------------------------------------------------

locals {
  argocd_shape_a = var.shape == "A"

  # Placement is set PER COMPONENT rather than through global.*, because that is
  # what the wrapper does, and a component-level nodeSelector REPLACES the chart's
  # global default instead of merging with it. Set globally here it would render
  # {kubernetes.io/os: linux, pool: infra} against the wrapper's {pool: infra}, and
  # wave 5 would rewrite every pod template -- a rolling restart of the control
  # plane -- to drop one key.
  argocd_placement = {
    nodeSelector = local.argocd_shape_a ? { pool = "infra" } : {}
    tolerations = local.argocd_shape_a ? [{
      key      = "workload"
      operator = "Equal"
      value    = "infra"
      effect   = "NoSchedule"
    }] : []
  }

  # Hard spread by hostname. The selector label is <nameOverride>-<component>, and
  # the chart defaults nameOverride to "argocd". It is NOT derived from
  # fullnameOverride: a prefixed name here would match zero pods, leaving skew
  # permanently 0 and the constraint vacuously satisfied while looking enforced.
  # (The identity-provider chart shipped exactly that bug; see
  # ../../docs/pool-rightsizing.md.)
  argocd_spread = {
    for component in ["server", "repo-server"] : component => [{
      maxSkew           = 1
      topologyKey       = "kubernetes.io/hostname"
      whenUnsatisfiable = "DoNotSchedule"
      labelSelector     = { matchLabels = { "app.kubernetes.io/name" = "argocd-${component}" } }
    }]
  }

  argocd_values = {
    # Pinning fullnameOverride makes object names stop depending on the release
    # name at all, and declares the same contract the wrapper declares.
    fullnameOverride = var.argocd_release_name

    global = {
      # Soft on the single-zone shape, hard once var.ha gives enough distinct
      # nodes. Hard anti-affinity on a small cluster leaves surplus replicas Pending.
      affinity          = { podAntiAffinity = var.ha ? "hard" : "soft" }
      priorityClassName = "system-cluster-critical"
    }

    configs = {
      # server.rootpath is deliberately NOT set: wave 5 adds it together with the
      # route, and until then a plain port-forward to / is the only way in.
      params = { "server.insecure" = true }

      # configs.secret stays at its default (createSecret = true). THIS install
      # creates argocd-secret (signature key, local admin hash). The wrapper sets
      # createSecret: false precisely so wave 5 never rewrites them. The asymmetry
      # is the point -- do not "align" it.
    }

    # Single-active by design; more replicas only help when sharding across
    # several managed clusters, which this island install does not do.
    controller = merge(local.argocd_placement, {
      replicas  = 1
      resources = { requests = { cpu = "250m", memory = "512Mi" }, limits = { cpu = "1", memory = "2Gi" } }
    })

    server = merge(local.argocd_placement, {
      replicas                  = 2
      service                   = { type = "ClusterIP" }
      ingress                   = { enabled = false } # the route arrives as a Gateway API HTTPRoute
      pdb                       = { enabled = true, maxUnavailable = 1 }
      topologySpreadConstraints = local.argocd_spread["server"]
      resources                 = { requests = { cpu = "100m", memory = "128Mi" }, limits = { cpu = "500m", memory = "512Mi" } }
    })

    # Renders every chart. Charts come from git at a pinned tag with vendored
    # subcharts, so it needs no registry egress, but it does need memory.
    repoServer = merge(local.argocd_placement, {
      replicas                  = 2
      pdb                       = { enabled = true, maxUnavailable = 1 }
      topologySpreadConstraints = local.argocd_spread["repo-server"]
      resources                 = { requests = { cpu = "100m", memory = "256Mi" }, limits = { cpu = "1", memory = "1Gi" } }
    })

    # Required: the platform is delivered by an ApplicationSet.
    applicationSet = merge(local.argocd_placement, {
      enabled   = true
      replicas  = 1
      resources = { requests = { cpu = "50m", memory = "128Mi" }, limits = { cpu = "500m", memory = "512Mi" } }
    })

    # No configured receiver: an enabled controller with nothing to notify is a
    # component to patch and monitor for no benefit.
    notifications = { enabled = false }

    # The manifest cache, NOT a datastore: losing it costs a re-render, not data.
    # redis-ha would be six pods that, under soft anti-affinity, can all land on
    # one node -- the cost of HA with none of the redundancy.
    redis = merge(local.argocd_placement, {
      enabled   = true
      resources = { requests = { cpu = "50m", memory = "64Mi" }, limits = { cpu = "200m", memory = "256Mi" } }
    })

    # Keycloak is the identity provider and Argo CD talks to it directly through
    # the oidc.config wave 5 adds. Dex would be a second, unused hop.
    dex = { enabled = false }
  }
}

resource "helm_release" "argocd" {
  # `name` forces replacement, so it has to be right before the first apply.
  name             = var.argocd_release_name
  namespace        = var.argocd_namespace
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  # atomic rolls back a release that does not converge. The generous timeout is
  # because the first install may wait for the autoscaler to add an infra node.
  atomic  = true
  wait    = true
  timeout = var.argocd_install_timeout

  values = [yamlencode(local.argocd_values)]

  depends_on = [
    azurerm_kubernetes_cluster_node_pool.user,
    azurerm_role_assignment.aks_acr_pull,
  ]

  # FROZEN after the wave-5 hand-off. From wave 5 on, Argo CD applies these
  # manifests with server-side apply and owns the fields, while this state still
  # records OpenTofu as the owner; the next apply that touched the release would
  # fight it. Argo CD upgrades itself from then on, and var.argocd_chart_version
  # only governs a fresh bootstrap. On a brand-new cluster, apply once, pass the
  # wave-5 gate (gitops/platform), and only then rely on this block; until the gate
  # passes, `helm rollback` of this release is the rollback path.
  #
  # Optionally follow with `tofu state rm helm_release.argocd` so there is one
  # owner on paper as well as in practice.
  lifecycle {
    ignore_changes = all
  }
}
