---
apiVersion: cloud.google.com/v1
kind: ComputeClass
metadata:
  name: $name
spec:
  priorities:
    - tpu:
        type: $accelerator_type
        count: $chips_per_node
        topology: $topology
      # Specific, because the reservation is specificReservationRequired: a
      # node that does not name it asks for on-demand capacity and fails.
      reservations:
        affinity: Specific
        specific:
          - name: $reservation_name
            project: $reservation_project
            # The reservation is zonal and the cluster pins no zones, so this
            # is the only thing keeping a node out of a zone that cannot serve
            # it. It belongs on the reservation and not in spec.location, which
            # GKE Warden rejects outright next to a specific reservation.
            zones: $zones
  nodePoolAutoCreation:
    enabled: true
  nodePoolConfig:
    # Otherwise an auto-created pool runs as the project's default compute
    # account, which carries far more than a node needs.
    serviceAccount: $node_service_account
    # A test image here is tens of gigabytes and a pod reads part of it, so
    # starting before the pull finishes is most of the cold start.
    imageStreaming:
      enabled: true
  # One reservation, and no on-demand fallback worth having: a TPU this lane
  # cannot reserve should leave the work queued until a node frees up, not
  # quietly buy capacity at list price. Explicit because the default changed in
  # 1.33.
  whenUnsatisfiable: DoNotScaleUp
