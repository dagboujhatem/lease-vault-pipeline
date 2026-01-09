#!/bin/bash
set -e

# Script pour lister tous les leases Vault
# Si LEASE_LIST_PATHS est spécifié, liste uniquement les leases de ces paths
# Sinon, liste tous les leases

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
OUTPUT_FILE="${OUTPUT_FILE:-leases.json}"

if [ -z "$VAULT_TOKEN" ]; then
    echo "Erreur: VAULT_TOKEN n'est pas défini"
    exit 1
fi

echo "Connexion à Vault: $VAULT_ADDR"

# Initialiser le tableau JSON pour stocker tous les leases
echo "[]" > "$OUTPUT_FILE"

# Fonction récursive pour explorer les paths de leases
explore_lease_path() {
    local prefix=$1
    local depth=${2:-0}
    
    # Limiter la profondeur de récursion pour éviter les boucles infinies
    if [ "$depth" -gt 50 ]; then
        echo "  ⚠ Profondeur maximale atteinte pour: $prefix"
        return
    fi
    
    echo "Exploration du path: ${prefix:-'(racine)'} (profondeur: $depth)"
    
    # Nettoyer le prefix pour l'URL
    local url_prefix=""
    if [ -n "$prefix" ] && [ "$prefix" != "." ]; then
        url_prefix=$(echo "$prefix" | sed 's|^/||;s|/$||;s|//|/|g')
    fi
    
    # Utiliser LIST pour obtenir les sous-chemins
    local list_url
    if [ -z "$url_prefix" ]; then
        list_url="$VAULT_ADDR/v1/sys/leases/subkeys/"
    else
        list_url="$VAULT_ADDR/v1/sys/leases/subkeys/$url_prefix"
    fi
    
    local response=$(curl -s \
        --header "X-Vault-Token: $VAULT_TOKEN" \
        --request LIST \
        "$list_url" 2>/dev/null || echo "{}")
    
    # Vérifier si c'est une erreur
    local error=$(echo "$response" | jq -r '.errors[]?' 2>/dev/null || echo "")
    if [ -n "$error" ] && [ "$error" != "null" ]; then
        # Peut-être que c'est un lease final, essayer de l'obtenir
        if [ -n "$prefix" ] && [ "$prefix" != "." ]; then
            get_lease_details "$prefix"
        fi
        return
    fi
    
    # Extraire les clés
    local subkeys=$(echo "$response" | jq -r '.data.keys[]?' 2>/dev/null || echo "")
    
    if [ -z "$subkeys" ] || [ "$subkeys" = "null" ]; then
        # C'est un lease final, essayer de l'obtenir
        if [ -n "$prefix" ] && [ "$prefix" != "." ]; then
            get_lease_details "$prefix"
        fi
        return
    fi
    
    # Parcourir récursivement les sous-chemins
    while IFS= read -r subkey; do
        if [ -z "$subkey" ]; then
            continue
        fi
        
        # Construire le nouveau prefix
        if [ -z "$prefix" ] || [ "$prefix" = "." ]; then
            new_prefix="$subkey"
        else
            new_prefix="$prefix/$subkey"
        fi
        
        # Nettoyer les slashes doubles et les slashes au début/fin
        new_prefix=$(echo "$new_prefix" | sed 's|^/||;s|/$||;s|//|/|g')
        
        explore_lease_path "$new_prefix" $((depth + 1))
    done <<< "$subkeys"
}

# Fonction pour obtenir les détails d'un lease
get_lease_details() {
    local lease_path=$1
    
    # Essayer d'obtenir les détails du lease
    local lease_details=$(curl -s \
        --header "X-Vault-Token: $VAULT_TOKEN" \
        "$VAULT_ADDR/v1/sys/leases/lookup/$lease_path" 2>/dev/null || echo "{}")
    
    # Vérifier si c'est un lease valide
    local lease_data=$(echo "$lease_details" | jq -r '.data' 2>/dev/null)
    
    if [ "$lease_data" != "null" ] && [ -n "$lease_data" ] && [ "$lease_data" != "" ]; then
        echo "  ✓ Lease trouvé: $lease_path"
        
        # Extraire le path et le lease_id
        local path=$(dirname "$lease_path")
        local lease_id=$(basename "$lease_path")
        
        # Ajouter le lease au fichier JSON
        local lease_json=$(echo "$lease_details" | jq -c --arg path "$path" --arg lease_id "$lease_id" --arg full_path "$lease_path" '{
            path: ($path | if . == "." then "" else . end),
            lease_id: $lease_id,
            full_path: $full_path,
            data: .data,
            orphan: (.data.orphan // false),
            renewable: (.data.renewable // false),
            ttl: (.data.ttl // 0),
            issue_time: (.data.issue_time // "")
        }')
        
        # Ajouter au fichier JSON
        jq --argjson lease "$lease_json" '. += [$lease]' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
    fi
}

# Fonction pour obtenir les leases d'un path spécifique
get_leases_from_path() {
    local path=$1
    echo "Traitement du path: $path"
    explore_lease_path "$path"
}

# Fonction pour lister tous les paths de leases
list_all_lease_paths() {
    echo "Liste de tous les paths de leases..."
    # Explorer depuis la racine
    explore_lease_path ""
}

# Si LEASE_LIST_PATHS est défini, traiter uniquement ces paths
if [ -n "$LEASE_LIST_PATHS" ]; then
    echo "Paths spécifiés: $LEASE_LIST_PATHS"
    IFS=',' read -ra PATHS <<< "$LEASE_LIST_PATHS"
    for path in "${PATHS[@]}"; do
        # Nettoyer les espaces
        path=$(echo "$path" | xargs)
        if [ -n "$path" ]; then
            get_leases_from_path "$path"
        fi
    done
else
    echo "Aucun path spécifié, liste de tous les leases..."
    list_all_lease_paths
fi

# Afficher un résumé
total=$(jq '. | length' "$OUTPUT_FILE")
orphans=$(jq '[.[] | select(.orphan == true)] | length' "$OUTPUT_FILE")

echo "======================================"
echo "Résumé:"
echo "  Total de leases: $total"
echo "  Leases orphelins: $orphans"
echo "  Fichier de sortie: $OUTPUT_FILE"
echo "======================================"

