#!/bin/sh
# dynamic_dns_plenor.sh
# Script de instalação do Cloudflare DDNS para pfSense
# Repositório: https://github.com/m4services/dynamic_dns_plenor
# Autor: M4 Services
# Data: 2026-01-13

set -e

echo "=========================================="
echo "  Cloudflare DDNS - Instalador pfSense"
echo "  M4 Services - Plenor"
echo "=========================================="
echo ""

# ========================================
# CONFIGURAÇÃO PRÉ-DEFINIDA
# ========================================
CF_TOKEN="MZ948yOKiggkErTfQp23Ttt6VOzMviPjMEttbnA0"
ZONE_NAME="plenor.com.br"
TTL=120
PROXIED="false"

# ========================================
# VARIÁVEL DINÂMICA (passada por parâmetro)
# ========================================
CLIENT_SUBDOMAIN="$1"

# Arquivos
PHP_SCRIPT="/conf/cf_ddns.php"
LOG_FILE="/var/log/cf_ddns.log"

# Validação do parâmetro
if [ -z "$CLIENT_SUBDOMAIN" ]; then
    echo "❌ ERRO: Subdomínio do cliente não informado!"
    echo ""
    echo "📋 USO CORRETO:"
    echo "   fetch -o - https://raw.githubusercontent.com/m4services/dynamic_dns_plenor/main/dynamic_dns_plenor.sh | sh -s -- cliente"
    echo ""
    echo "   Onde 'cliente' será: cliente.plenor.com.br"
    echo ""
    echo "EXEMPLOS:"
    echo "   sh dynamic_dns_plenor.sh barboza    → barboza.plenor.com.br"
    echo "   sh dynamic_dns_plenor.sh empresa1   → empresa1.plenor.com.br"
    echo "   sh dynamic_dns_plenor.sh loja-sp    → loja-sp.plenor.com.br"
    echo ""
    exit 1
fi

# Montar o FQDN completo
RECORD_FQDN="${CLIENT_SUBDOMAIN}.${ZONE_NAME}"

echo "✅ Configuração:"
echo "   Cliente: $CLIENT_SUBDOMAIN"
echo "   FQDN: $RECORD_FQDN"
echo "   Zona: $ZONE_NAME"
echo "   TTL: $TTL segundos"
echo ""

# Verificar se o arquivo já existe
if [ -f "$PHP_SCRIPT" ]; then
    echo "⚠️  Arquivo $PHP_SCRIPT já existe!"
    read -p "   Deseja sobrescrever? (s/n): " resposta
    if [ "$resposta" != "s" ] && [ "$resposta" != "S" ]; then
        echo "❌ Instalação cancelada."
        exit 1
    fi
    rm -f "$PHP_SCRIPT"
fi

# Criar o arquivo PHP
echo "📝 Criando $PHP_SCRIPT..."
cat > "$PHP_SCRIPT" << EOFPHP
<?php
// /conf/cf_ddns.php
// Cloudflare DDNS reconciler (A record) para pfSense
// Cliente: $CLIENT_SUBDOMAIN
// Gerado por: https://github.com/m4services/dynamic_dns_plenor

\$CF_TOKEN   = '$CF_TOKEN';
\$ZONE_NAME   = '$ZONE_NAME';
\$RECORD_FQDN = '$RECORD_FQDN';
\$TTL         = $TTL;
\$PROXIED     = $PROXIED;
\$LOG         = '/var/log/cf_ddns.log';
\$LOCK        = '/tmp/cf_ddns.lock';

// Rotação do log
\$MAX_LOG_BYTES = 512 * 1024;
\$MAX_LOG_FILES = 3;

function rotate_log_if_needed() {
  global \$LOG, \$MAX_LOG_BYTES, \$MAX_LOG_FILES;
  if (!file_exists(\$LOG)) return;
  clearstatcache(true, \$LOG);
  \$size = filesize(\$LOG);
  if (\$size === false || \$size <= \$MAX_LOG_BYTES) return;
  
  for (\$i = \$MAX_LOG_FILES; \$i >= 2; \$i--) {
    \$src = \$LOG . '.' . (\$i - 1);
    \$dst = \$LOG . '.' . \$i;
    if (file_exists(\$src)) @rename(\$src, \$dst);
  }
  @rename(\$LOG, \$LOG . '.1');
}

function logmsg(\$m) {
  global \$LOG;
  rotate_log_if_needed();
  file_put_contents(\$LOG, date('c') . " " . \$m . PHP_EOL, FILE_APPEND);
}

function http_json(\$method, \$url, \$token, \$body = null) {
  \$ch = curl_init(\$url);
  \$headers = [
    "Authorization: Bearer {\$token}",
    "Content-Type: application/json",
  ];
  curl_setopt_array(\$ch, [
    CURLOPT_CUSTOMREQUEST => \$method,
    CURLOPT_HTTPHEADER => \$headers,
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_CONNECTTIMEOUT => 5,
    CURLOPT_TIMEOUT => 12,
  ]);
  if (\$body !== null) {
    curl_setopt(\$ch, CURLOPT_POSTFIELDS, json_encode(\$body));
  }
  \$resp = curl_exec(\$ch);
  \$code = curl_getinfo(\$ch, CURLINFO_HTTP_CODE);
  \$err  = curl_error(\$ch);
  curl_close(\$ch);
  
  if (\$resp === false) throw new Exception("HTTP error: {\$err}");
  \$json = json_decode(\$resp, true);
  if (!is_array(\$json)) throw new Exception("Invalid JSON response (HTTP {\$code})");
  if (\$code >= 400 || empty(\$json['success'])) {
    \$e = isset(\$json['errors']) ? json_encode(\$json['errors']) : \$resp;
    throw new Exception("Cloudflare API failed (HTTP {\$code}): {\$e}");
  }
  return \$json;
}

function get_public_ip() {
  \$sources = [
    "https://api.ipify.org",
    "https://checkip.amazonaws.com",
  ];
  foreach (\$sources as \$u) {
    \$ctx = stream_context_create([
      'http' => ['timeout' => 5],
      'ssl'  => ['verify_peer' => true, 'verify_peer_name' => true],
    ]);
    \$ip = @trim(file_get_contents(\$u, false, \$ctx));
    if (filter_var(\$ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) return \$ip;
  }
  throw new Exception("Could not determine public IPv4");
}

// Lock mechanism
\$fp = fopen(\$LOCK, 'c');
if (!\$fp || !flock(\$fp, LOCK_EX | LOCK_NB)) exit(0);

try {
  \$ip = get_public_ip();
  
  // Get Zone ID
  \$z = http_json("GET", "https://api.cloudflare.com/client/v4/zones?name=" . urlencode(\$ZONE_NAME), \$CF_TOKEN);
  \$zone_id = \$z['result'][0]['id'] ?? null;
  if (!\$zone_id) throw new Exception("Zone not found: {\$ZONE_NAME}");
  
  // Get DNS Record
  \$r = http_json("GET",
    "https://api.cloudflare.com/client/v4/zones/{\$zone_id}/dns_records?type=A&name=" . urlencode(\$RECORD_FQDN),
    \$CF_TOKEN
  );
  \$rec = \$r['result'][0] ?? null;
  if (!\$rec) throw new Exception("DNS record not found: {\$RECORD_FQDN}");
  
  \$current   = \$rec['content'] ?? '';
  \$record_id = \$rec['id'];
  
  // Skip if no change
  if (\$current === \$ip) exit(0);
  
  // Update record
  \$payload = [
    "type" => "A",
    "name" => \$RECORD_FQDN,
    "content" => \$ip,
    "ttl" => \$TTL,
    "proxied" => \$PROXIED,
  ];
  http_json("PUT",
    "https://api.cloudflare.com/client/v4/zones/{\$zone_id}/dns_records/{\$record_id}",
    \$CF_TOKEN,
    \$payload
  );
  
  logmsg("UPDATED {\$RECORD_FQDN}: {\$current} -> {\$ip}");
  
} catch (Exception \$e) {
  logmsg("ERROR {\$RECORD_FQDN}: " . \$e->getMessage());
  exit(2);
} finally {
  flock(\$fp, LOCK_UN);
  fclose(\$fp);
}
EOFPHP

chmod 755 "$PHP_SCRIPT"
echo "✅ Arquivo criado e permissões configuradas"

# Testar o script
echo ""
echo "🧪 Testando execução..."
if /usr/local/bin/php -f "$PHP_SCRIPT"; then
    echo "✅ Script testado com sucesso!"
    echo ""
    if [ -f "$LOG_FILE" ]; then
        echo "📄 Últimas linhas do log:"
        tail -3 "$LOG_FILE"
    fi
else
    echo "⚠️  Teste executado com avisos. Verifique: $LOG_FILE"
fi

# Configurar Cron Job automaticamente
echo ""
echo "⏰ Configurando Cron Job..."

CRON_CMD="/usr/local/bin/php -f /conf/cf_ddns.php"
CRON_EXISTS=$(grep -c "$CRON_CMD" /etc/crontab 2>/dev/null || echo "0")

if [ "$CRON_EXISTS" -gt 0 ]; then
    echo "✅ Cron job já existe no sistema"
else
    # Adicionar ao crontab
    echo "*/2 * * * * root $CRON_CMD" >> /etc/crontab
    echo "✅ Cron job adicionado ao /etc/crontab"
fi

# Recarregar cron
/usr/sbin/service cron reload >/dev/null 2>&1 || /etc/rc.d/cron reload >/dev/null 2>&1 || true
echo "✅ Serviço cron recarregado"

# Salvar configuração para persistir após reboot
if [ -f /cf/conf/config.xml ]; then
    # Backup do config
    cp /cf/conf/config.xml /cf/conf/config.xml.bak
    
    # Adicionar ao config.xml se não existir
    if ! grep -q "$CRON_CMD" /cf/conf/config.xml 2>/dev/null; then
        # Criar entrada de cron via pfSense config
        php -r "
        require_once('config.inc');
        require_once('cron.inc');
        
        \$cron_item = array();
        \$cron_item['minute'] = '*/2';
        \$cron_item['hour'] = '*';
        \$cron_item['mday'] = '*';
        \$cron_item['month'] = '*';
        \$cron_item['wday'] = '*';
        \$cron_item['who'] = 'root';
        \$cron_item['command'] = '$CRON_CMD';
        
        if (!is_array(\$config['cron'])) {
            \$config['cron'] = array();
        }
        if (!is_array(\$config['cron']['item'])) {
            \$config['cron']['item'] = array();
        }
        
        // Verificar se já existe
        \$exists = false;
        foreach (\$config['cron']['item'] as \$item) {
            if (\$item['command'] == '$CRON_CMD') {
                \$exists = true;
                break;
            }
        }
        
        if (!\$exists) {
            \$config['cron']['item'][] = \$cron_item;
            write_config('Added Cloudflare DDNS cron job');
            configure_cron();
        }
        " 2>/dev/null && echo "✅ Cron job salvo na configuração do pfSense"
    fi
fi

# Instruções finais
echo ""
echo "=========================================="
echo "  ✅ INSTALAÇÃO COMPLETA!"
echo "=========================================="
echo ""
echo "🌐 DNS configurado: $RECORD_FQDN"
echo "⏰ Cron job: Ativo (a cada 2 minutos)"
echo "📊 Monitoramento: tail -f $LOG_FILE"
echo ""
echo "🔄 Para outro cliente:"
echo "   fetch -o - https://raw.githubusercontent.com/m4services/dynamic_dns_plenor/main/dynamic_dns_plenor.sh | sh -s -- outro-cliente"
echo ""
echo "🗑️  Para desinstalar:"
echo "   rm -f /conf/cf_ddns.php /var/log/cf_ddns.log*"
echo "   (Remova o cron em Services > Cron na interface web)"
echo "=========================================="
echo ""
