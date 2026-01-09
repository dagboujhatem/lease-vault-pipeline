#!/bin/bash
# Script de récupération après suppression accidentelle de leases
# Usage: ./scripts/recover-leases.sh <namespace> [backup-file]

set -e

NAMESPACE="${1:-}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
BACKUP_FILE="${2:-leases.json.backup}"

if [ -z "$NAMESPACE" ]; then
    echo "Usage: $0 <namespace> [backup-file]"
    echo ""
    echo "Exemple:"
    echo "  $0 my-app-prod leases.json.backup-20240101-120000"
    exit 1
fi

echo "=========================================="
echo "Procédure de Récupération pour namespace: $NAMESPACE"
echo "=========================================="
echo ""

# 1. Évaluer l'impact
echo "1. Évaluation de l'impact..."
pod_count=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
echo "  Pods dans le namespace: $pod_count"

deployment_count=$(kubectl get deployments -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
echo "  Deployments dans le namespace: $deployment_count"

statefulset_count=$(kubectl get statefulsets -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
if [ "$statefulset_count" -gt 0 ]; then
    echo "  StatefulSets dans le namespace: $statefulset_count"
fi

failed_pods=$(kubectl get pods -n "$NAMESPACE" --field-selector=status.phase!=Running --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
if [ "$failed_pods" -gt 0 ]; then
    echo "  ⚠️ Pods en erreur: $failed_pods"
    echo ""
    echo "  Liste des pods en erreur:"
    kubectl get pods -n "$NAMESPACE" --field-selector=status.phase!=Running -o wide 2>/dev/null || echo "    (aucun)"
else
    echo "  ✓ Aucun pod en erreur détecté"
fi

# 2. Afficher les leases détruits (si backup disponible)
echo ""
if [ -f "$BACKUP_FILE" ]; then
    echo "2. Leases détruits (selon backup: $BACKUP_FILE):"
    if command -v jq >/dev/null 2>&1; then
        total_leases=$(jq '. | length' "$BACKUP_FILE" 2>/dev/null || echo "0")
        echo "  Total de leases dans le backup: $total_leases"
        
        orphan_leases=$(jq '[.[] | select(.orphan == true)] | length' "$BACKUP_FILE" 2>/dev/null || echo "0")
        echo "  Leases orphelins dans le backup: $orphan_leases"
        
        echo ""
        echo "  Premiers leases détruits:"
        jq -r '.[] | "    - \(.full_path) (orphan: \(.orphan // false))"' "$BACKUP_FILE" 2>/dev/null | head -10 || echo "    (erreur lors de la lecture)"
        echo "    ... (voir $BACKUP_FILE pour la liste complète)"
    else
        echo "  ⚠️ jq n'est pas installé, impossible de lire le fichier JSON"
        echo "  Fichier backup: $BACKUP_FILE"
    fi
else
    echo "2. ⚠️ Aucun fichier backup trouvé: $BACKUP_FILE"
    echo "   Recherche de fichiers backup..."
    if ls leases.json.backup* 2>/dev/null | head -1 | read latest_backup; then
        echo "   Fichier trouvé: $latest_backup"
        echo "   Utilisez: $0 $NAMESPACE $latest_backup"
    else
        echo "   Aucun fichier backup trouvé"
    fi
fi

# 3. Proposer la récupération
echo ""
echo "3. Procédure de récupération proposée:"
echo ""
echo "   a) Redémarrer les deployments (RECOMMANDÉ):"
echo "      kubectl rollout restart deployment -n $NAMESPACE"
echo ""
if [ "$statefulset_count" -gt 0 ]; then
    echo "   b) Redémarrer les statefulsets:"
    echo "      kubectl rollout restart statefulset -n $NAMESPACE"
    echo ""
fi
echo "   c) OU supprimer les pods:"
echo "      kubectl delete pods -n $NAMESPACE --all"
echo ""
echo "   d) Vérifier le statut:"
echo "      kubectl get pods -n $NAMESPACE"
echo "      kubectl rollout status deployment -n $NAMESPACE"
echo ""
echo "4. Après récupération, vérifier les nouveaux leases:"
if [ -n "$VAULT_ADDR" ]; then
    echo "   export VAULT_ADDR=\"$VAULT_ADDR\""
fi
echo "   export LEASE_LIST_PATHS=\"<path-du-namespace>\""
echo "   ./scripts/list-lease.sh"
echo ""
echo "=========================================="
echo "⚠️ Voulez-vous procéder à la récupération ?"
echo "=========================================="
echo ""
read -p "Redémarrer les deployments du namespace $NAMESPACE ? (yes/no): " confirm

if [ "$confirm" = "yes" ]; then
    echo ""
    echo "Redémarrage des deployments..."
    
    # Redémarrer les deployments
    if [ "$deployment_count" -gt 0 ]; then
        kubectl rollout restart deployment -n "$NAMESPACE"
        
        echo ""
        echo "Attente du redéploiement (timeout: 5 minutes)..."
        timeout 300 kubectl rollout status deployment -n "$NAMESPACE" --timeout=300s 2>&1 || {
            echo "⚠️ Le timeout a été atteint ou une erreur s'est produite"
            echo "Vérifiez manuellement le statut des pods"
        }
    else
        echo "  Aucun deployment trouvé dans le namespace"
    fi
    
    # Redémarrer les statefulsets si présents
    if [ "$statefulset_count" -gt 0 ]; then
        echo ""
        echo "Redémarrage des statefulsets..."
        kubectl rollout restart statefulset -n "$NAMESPACE"
    fi
    
    echo ""
    echo "✓ Récupération terminée"
    echo ""
    echo "Vérifiez maintenant que les pods sont Running:"
    echo "  kubectl get pods -n $NAMESPACE"
    echo ""
    echo "Surveillez les pods jusqu'à ce qu'ils soient tous Running:"
    echo "  watch kubectl get pods -n $NAMESPACE"
else
    echo ""
    echo "Récupération annulée. Exécutez manuellement les commandes ci-dessus."
    echo ""
    echo "Pour plus d'informations, consultez le fichier recuperation.md"
fi

