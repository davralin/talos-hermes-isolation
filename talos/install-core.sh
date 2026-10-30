#!/usr/bin/env bash
set -euo pipefail

helm repo add cilium https://helm.cilium.io
helm repo update cilium

helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --version 1.20.4 \
  --timeout 10m \
  --set cgroup.autoMount.enabled=false \
  --set cgroup.hostRoot=/sys/fs/cgroup \
  --set certgen.enforceCAValidityThroughoutLeavesDuration=false \
  --set ingressController.enabled=false \
  --set ipam.mode=kubernetes \
  --set k8sServiceHost=localhost \
  --set k8sServicePort=7445 \
  --set kubeProxyReplacement=true \
  --set socketLB.hostNamespaceOnly=true \
  --set l2announcements.enabled=true \
  --set loadBalancer.mode=snat \
  --set hubble.enabled=true \
  --set hubble.tls.auto.enabled=true \
  --set hubble.tls.auto.method=cronJob \
  --set hubble.tls.auto.certValidityDuration=1095 \
  --set hubble.tls.auto.schedule='0 0 1 */4 *' \
  --set hubble.relay.enabled=true \
  --set hubble.relay.rollOutPods=true \
  --set hubble.ui.enabled=true \
  --set hubble.ui.rollOutPods=true \
  --set hubble.ui.ingress.enabled=false \
  --set-json 'securityContext.capabilities.ciliumAgent=["CHOWN","KILL","NET_ADMIN","NET_RAW","IPC_LOCK","SYS_ADMIN","SYS_RESOURCE","DAC_OVERRIDE","FOWNER","SETGID","SETUID"]' \
  --set-json 'securityContext.capabilities.cleanCiliumState=["NET_ADMIN","SYS_ADMIN","SYS_RESOURCE"]' \
  --set operator.replicas=1

kubectl -n kube-system rollout status daemonset/cilium --timeout=10m
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=10m
kubectl -n kube-system wait --for=condition=complete job -l k8s-app=hubble-generate-certs --timeout=10m
kubectl -n kube-system rollout restart daemonset/cilium
kubectl -n kube-system rollout status daemonset/cilium --timeout=10m
kubectl -n kube-system rollout status deployment/hubble-relay --timeout=10m
kubectl -n kube-system rollout status deployment/hubble-ui --timeout=10m

helm upgrade --install flux2 oci://ghcr.io/fluxcd-community/charts/flux2 \
  --namespace flux-system \
  --create-namespace \
  --version 2.19.1 \
  --wait \
  --timeout 10m \
  --set installCRDs=true \
  --set policies.create=true \
  --set rbac.create=true \
  --set rbac.createAggregation=true \
  --set watchAllNamespaces=true
