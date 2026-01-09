#!/bin/bash
set -e

# Script de pré-vérification des capacités Vault
# Vérifie que le token a toutes les permissions nécessaires pour lister et détruire les leases

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN}"

if [ -z "$VAULT_TOKEN" ]; then
    echo "❌ Erreur: VAULT_TOKEN n'est pas défini"
    exit 1
fi

if [ -z "$VAULT_ADDR" ]; then
    echo "❌ Erreur: VAULT_ADDR n'est pas défini"
    exit 1
fi

echo "=========================================="
echo "Vérification des capacités Vault"
echo "=========================================="
echo "Vault Address: $VAULT_ADDR"
echo ""

# Couleurs pour l'affichage (si supporté)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

# Variables pour le résultat final
ALL_CHECKS_PASSED=true
FAILED_CHECKS=()

# Fonction pour vérifier une capacité sur un path
check_capability() {
    local path=$1
    local required_capability=$2
    local description=$3
    
    echo -n "Vérification: $description ... "
    
    # Appel à l'API Vault pour vérifier les capacités
    local response=$(curl -s \
        --header "X-Vault-Token: $VAULT_TOKEN" \
        --request POST \
        --data "{\"paths\": [\"$path\"]}" \
        "$VAULT_ADDR/v1/sys/capabilities" 2>/dev/null || echo "{}")
    
    # Vérifier si c'est une erreur
    local errors=$(echo "$response" | jq -r '.errors[]?' 2>/dev/null || echo "")
    if [ -n "$errors" ] && [ "$errors" != "null" ]; then
        echo -e "${RED}✗ ERREUR${NC}"
        echo "  Détail: $errors"
        ALL_CHECKS_PASSED=false
        FAILED_CHECKS+=("$description")
        return 1
    fi
    
    # Extraire les capacités pour ce path
    local capabilities=$(echo "$response" | jq -r ".[\"$path\"][]?" 2>/dev/null || echo "")
    
    if [ -z "$capabilities" ] || [ "$capabilities" = "null" ]; then
        echo -e "${RED}✗ Aucune capacité trouvée${NC}"
        ALL_CHECKS_PASSED=false
        FAILED_CHECKS+=("$description")
        return 1
    fi
    
    # Vérifier si la capacité requise est présente
    local has_capability=false
    while IFS= read -r cap; do
        if [ "$cap" = "$required_capability" ] || [ "$cap" = "root" ] || [ "$cap" = "sudo" ]; then
            has_capability=true
            break
        fi
        # Gérer le cas où on a "deny" (pas de permission)
        if [ "$cap" = "deny" ]; then
            has_capability=false
            break
        fi
    done <<< "$capabilities"
    
    if [ "$has_capability" = true ]; then
        echo -e "${GREEN}✓ OK${NC}"
        echo "  Capacités disponibles: $(echo "$capabilities" | tr '\n' ',' | sed 's/,$//')"
        return 0
    else
        echo -e "${RED}✗ MANQUANT${NC}"
        echo "  Capacité requise: $required_capability"
        echo "  Capacités disponibles: $(echo "$capabilities" | tr '\n' ',' | sed 's/,$//')"
        ALL_CHECKS_PASSED=false
        FAILED_CHECKS+=("$description")
        return 1
    fi
}

# Fonction pour tester une opération réelle
test_operation() {
    local operation=$1
    local description=$2
    local test_url=$3
    local http_method=${4:-GET}
    
    echo -n "Test opération: $description ... "
    
    local response
    if [ "$http_method" = "LIST" ]; then
        response=$(curl -s -w "\n%{http_code}" \
            --header "X-Vault-Token: $VAULT_TOKEN" \
            --request LIST \
            "$test_url" 2>/dev/null || echo -e "\n000")
    else
        response=$(curl -s -w "\n%{http_code}" \
            --header "X-Vault-Token: $VAULT_TOKEN" \
            --request "$http_method" \
            "$test_url" 2>/dev/null || echo -e "\n000")
    fi
    
    local http_code=$(echo "$response" | tail -n1)
    local response_body=$(echo "$response" | head -n-1)
    
    # Vérifier le code HTTP
    case "$http_code" in
        200|204)
            echo -e "${GREEN}✓ OK${NC}"
            return 0
            ;;
        403)
            echo -e "${RED}✗ PERMISSION REFUSÉE${NC}"
            local error=$(echo "$response_body" | jq -r '.errors[]?' 2>/dev/null || echo "Permission refusée")
            echo "  Détail: $error"
            ALL_CHECKS_PASSED=false
            FAILED_CHECKS+=("$description")
            return 1
            ;;
        404)
            echo -e "${YELLOW}⚠ Path non trouvé (peut être normal si aucun lease n'existe)${NC}"
            return 0  # Pas une erreur critique pour un test
            ;;
        401)
            echo -e "${RED}✗ TOKEN INVALIDE${NC}"
            echo "  Le token fourni n'est pas valide ou a expiré"
            ALL_CHECKS_PASSED=false
            FAILED_CHECKS+=("$description")
            return 1
            ;;
        *)
            echo -e "${RED}✗ ERREUR (HTTP $http_code)${NC}"
            local error=$(echo "$response_body" | jq -r '.errors[]?' 2>/dev/null || echo "Erreur inconnue")
            echo "  Détail: $error"
            ALL_CHECKS_PASSED=false
            FAILED_CHECKS+=("$description")
            return 1
            ;;
    esac
}

echo "Vérification des capacités sur les paths système..."
echo ""

# Vérifier les capacités pour lister les leases
check_capability "sys/leases/subkeys/" "list" "Capacité 'list' sur sys/leases/subkeys/"
check_capability "sys/leases/subkeys/" "read" "Capacité 'read' sur sys/leases/subkeys/"
check_capability "sys/leases/lookup/test" "read" "Capacité 'read' sur sys/leases/lookup/*"

# Vérifier la capacité pour détruire les leases (optionnel si on ne veut pas détruire)
if [ "${CHECK_REVOKE_CAPABILITY:-true}" = "true" ]; then
    check_capability "sys/leases/revoke/test" "update" "Capacité 'update' sur sys/leases/revoke/*"
fi

echo ""
echo "Test des opérations réelles..."
echo ""

# Test 1: Lister les subkeys (opération réelle)
test_operation "list_subkeys" "Lister les paths de leases" "$VAULT_ADDR/v1/sys/leases/subkeys/" "LIST"

# Test 2: Lookup d'un lease (si des leases existent, sinon 404 est acceptable)
# On utilise un path qui n'existe probablement pas, mais ça teste la permission
test_operation "lookup_lease" "Lookup d'un lease (test de permission)" "$VAULT_ADDR/v1/sys/leases/lookup/test-lease-check" "GET"

echo ""
echo "=========================================="
echo "Résumé de la vérification"
echo "=========================================="

# Vérifier les informations du token
echo "Informations du token:"
token_info=$(curl -s \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    "$VAULT_ADDR/v1/auth/token/lookup-self" 2>/dev/null || echo "{}")

token_ttl=$(echo "$token_info" | jq -r '.data.ttl // 0' 2>/dev/null || echo "0")
token_policies=$(echo "$token_info" | jq -r '.data.policies[]?' 2>/dev/null || echo "")

if [ -n "$token_policies" ] && [ "$token_policies" != "null" ]; then
    echo "  Policies associées: $(echo "$token_policies" | tr '\n' ',' | sed 's/,$//')"
else
    echo "  ⚠ Aucune policy trouvée"
fi

if [ "$token_ttl" -gt 0 ]; then
    echo "  TTL restant: ${token_ttl}s ($(($token_ttl / 3600))h)"
else
    echo "  ⚠ TTL: $token_ttl (token peut être expiré ou sans expiration)"
fi

echo ""

# Résultat final
if [ "$ALL_CHECKS_PASSED" = true ]; then
    echo -e "${GREEN}✓ Tous les tests de capacités ont réussi${NC}"
    echo ""
    echo "Le token a toutes les permissions nécessaires pour:"
    echo "  ✓ Lister les leases (list, read sur sys/leases/subkeys/*)"
    echo "  ✓ Lire les détails des leases (read sur sys/leases/lookup/*)"
    if [ "${CHECK_REVOKE_CAPABILITY:-true}" = "true" ]; then
        echo "  ✓ Détruire les leases (update sur sys/leases/revoke/*)"
    fi
    echo ""
    exit 0
else
    echo -e "${RED}✗ Certaines vérifications ont échoué${NC}"
    echo ""
    echo "Les vérifications suivantes ont échoué:"
    for check in "${FAILED_CHECKS[@]}"; do
        echo "  - $check"
    done
    echo ""
    echo "Actions recommandées:"
    echo "  1. Vérifiez que le token a les permissions nécessaires"
    echo "  2. Consultez la section 'Vérification des Capacités Vault' dans le README"
    echo "  3. Contactez votre administrateur Vault pour obtenir les permissions manquantes"
    echo ""
    exit 1
fi

