#!/bin/bash
set -e

# Script pour détruire les leases Vault
# Si DESTROY_ORPHANS_ONLY=true, détruit uniquement les leases orphelins
# Sinon, détruit tous les leases du fichier JSON

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
INPUT_FILE="${INPUT_FILE:-leases.json}"
DESTROY_ORPHANS_ONLY="${DESTROY_ORPHANS_ONLY:-false}"

if [ -z "$VAULT_TOKEN" ]; then
    echo "Erreur: VAULT_TOKEN n'est pas défini"
    exit 1
fi

if [ ! -f "$INPUT_FILE" ]; then
    echo "Erreur: Le fichier $INPUT_FILE n'existe pas"
    exit 1
fi

echo "Connexion à Vault: $VAULT_ADDR"
echo "Fichier d'entrée: $INPUT_FILE"
echo "Détruire uniquement les orphelins: $DESTROY_ORPHANS_ONLY"

# Filtrer les leases selon le mode
if [ "$DESTROY_ORPHANS_ONLY" = "true" ]; then
    echo "Filtrage des leases orphelins uniquement..."
    filtered_file="${INPUT_FILE}.orphans.json"
    jq '[.[] | select(.orphan == true)]' "$INPUT_FILE" > "$filtered_file"
    leases_file="$filtered_file"
else
    echo "Traitement de tous les leases..."
    leases_file="$INPUT_FILE"
fi

# Compter les leases à détruire
total_to_destroy=$(jq '. | length' "$leases_file")
echo "Nombre de leases à détruire: $total_to_destroy"

if [ "$total_to_destroy" -eq 0 ]; then
    echo "Aucun lease à détruire"
    # Nettoyer le fichier temporaire si créé
    [ -f "${INPUT_FILE}.orphans.json" ] && rm "${INPUT_FILE}.orphans.json"
    exit 0
fi

# Initialiser les compteurs
success_count=0
fail_count=0
failed_leases_file="${INPUT_FILE}.failed"

# Initialiser le fichier des échecs
> "$failed_leases_file"

# Parcourir tous les leases et les détruire
while IFS= read -r lease; do
    lease_path=$(echo "$lease" | jq -r '.full_path')
    lease_id=$(echo "$lease" | jq -r '.lease_id')
    path=$(echo "$lease" | jq -r '.path')
    is_orphan=$(echo "$lease" | jq -r '.orphan // false')
    
    echo "Destruction du lease: $lease_path (orphan: $is_orphan)"
    
    # Construire l'URL de révocation
    # Vault utilise le format: /sys/leases/revoke/{lease_id}
    # Pour les leases avec path: /sys/leases/revoke/{prefix}/{lease_id}
    if [ -z "$path" ] || [ "$path" = "." ] || [ "$path" = "null" ]; then
        revoke_url="$VAULT_ADDR/v1/sys/leases/revoke/$lease_id"
    else
        # Nettoyer le path (supprimer les slashes doubles)
        clean_path=$(echo "$path" | sed 's|^/||;s|/$||;s|//|/|g')
        revoke_url="$VAULT_ADDR/v1/sys/leases/revoke/$clean_path/$lease_id"
    fi
    
    # Détruire le lease via l'API Vault
    response=$(curl -s -w "\n%{http_code}" \
        --header "X-Vault-Token: $VAULT_TOKEN" \
        --request POST \
        "$revoke_url" 2>/dev/null || echo -e "\n000")
    
    http_code=$(echo "$response" | tail -n1)
    response_body=$(echo "$response" | head -n-1)
    
    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
        echo "  ✓ Lease détruit avec succès"
        success_count=$((success_count + 1))
    else
        error_msg=$(echo "$response_body" | jq -r '.errors[]?' 2>/dev/null || echo "Erreur inconnue (HTTP $http_code)")
        echo "  ✗ Échec de la destruction: $error_msg"
        fail_count=$((fail_count + 1))
        echo "$lease_path" >> "$failed_leases_file"
    fi
    
    # Petit délai pour éviter de surcharger Vault
    sleep 0.1
done < <(jq -c '.[]' "$leases_file")

echo "======================================"
echo "Résumé de la destruction:"
echo "  Total traité: $total_to_destroy"
echo "  Leases détruits avec succès: $success_count"
echo "  Échecs: $fail_count"
if [ -f "$failed_leases_file" ] && [ -s "$failed_leases_file" ]; then
    echo "  Leases en échec:"
    while read -r failed_lease; do
        [ -n "$failed_lease" ] && echo "    - $failed_lease"
    done < "$failed_leases_file"
fi
echo "======================================"

# Nettoyer les fichiers temporaires
[ -f "${INPUT_FILE}.orphans.json" ] && rm "${INPUT_FILE}.orphans.json"
[ -f "$failed_leases_file" ] && rm "$failed_leases_file"

# Sortir avec un code d'erreur si des échecs ont eu lieu
if [ "$fail_count" -gt 0 ]; then
    exit 1
fi
