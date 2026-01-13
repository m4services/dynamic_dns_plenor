#!/bin/sh
# setup_cf_ddns_pfsense.sh
# Script de instalação do Cloudflare DDNS para pfSense
# Autor: Adaptado para automação
# Data: 2026-01-13

set -e

echo "=== Instalação Cloudflare DDNS para pfSense ==="
echo ""

# Variáveis de configuração (edite conforme necessário)
CF_TOKEN="MZ948yOKiggkErTfQp23Ttt6VOzMviPjMEttbnA0"
ZONE_NAME="plenor.com.br"
RECORD_FQDN="cliente.plenor.com.br"
TTL=120
PROXIED="false"

# Arquivos
PHP_SCRIPT="/conf/cf_ddns.php"
LOG_FILE="/var/log/cf_ddns.log"

# Passo 1: Verificar se o arquivo já existe
if [ -f "$PHP_SCRIPT" ]; then
    echo "⚠️  Arquivo $PHP_SCRIPT já existe!"
    read -p "Deseja sobrescrever? (s/n): " resposta
    if [ "$resposta" != "s" ] && [ "$resposta" != "S" ]; then
        echo "Abortando instalação."
        exit 1
    fi
    rm -f "$PHP_SCRIPT"
fi

# Passo 2: Criar o arquivo PHP com o script DDNS
echo "📝 Criando arquivo $PHP_SCRIPT..."
cat > "$PHP_SCRIPT" << 'EOFPHP'
<?php
// /conf/cf_ddns.php
// Cloudflare DDNS reconciler (A record) para pfSense
// Loga somente UPDATE/ERROR + rotação simples do log

$CF_TOKEN   = 'MZ948yOKiggkErTfQp23Ttt6VOzMviPjMEttbnA0';
$ZONE_NAME   = 'plenor.com.br';
$RECORD_FQDN = 'barboza.plenor.com.br';   // ex: cliente.plenor.com.br
$TTL         = 120;                    // segundos (ou 1 para "Auto" em algumas contas)
$PROXIED     = false;                  // DNS only
$LOG         = '/var/log/cf_ddns.log';
$LOCK        = '/tmp/cf_ddns.lock';

// Rotação do log (pra não crescer infinito)
$MAX_LOG_BYTES = 512 * 1024;           // 512 KB
$MAX_LOG_FILES = 3;                    // mantém .1, .2, .3

function rotate_log_if_needed() {
  global $LOG, $MAX_LOG_BYTES, $MAX_LOG_FILES;
  if (!file_exists($LOG)) return;
  clearstatcache(true, $LOG);
  $size = filesize($LOG);
  if ($size === false || $size <= $MAX_LOG_BYTES) return;
  
  // move cf_ddns.log.2 -> .3 ... e cf_ddns.log -> .1
  for ($i = $MAX_LOG_FILES; $i >= 2; $i--) {
    $src = $LOG . '.' . ($i - 1);
    $dst = $LOG . '.' . $i;
    if (file_exists($src)) @rename($src, $dst);
  }
  @rename($LOG, $LOG . '.1');
}

function logmsg($m) {
  global $LOG;
  rotate_log_if_needed();
  file_put_contents($LOG, date('c') . " " . $m . PHP_EOL, FILE_APPEND);
}

function http_json($method, $url, $token, $body = null) {
  $ch = curl_init($url);
  $headers = [
    "Authorization: Bearer {$token}",
    "Content-Type: application/json",
  ];
  curl_setopt_array($ch, [
    CURLOPT_CUSTOMREQUEST => $method,
    CURLOPT_HTTPHEADER => $headers,
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_CONNECTTIMEOUT => 5,
    CURLOPT_TIMEOUT => 12,
  ]);
  if ($body !== null) {
    curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($body));
  }
  $resp = curl_exec($ch);
  $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
  $err  = curl_error($ch);
  curl_close($ch);
  
  if ($resp === false) throw new Exception("HTTP error: {$err}");
  $json = json_decode($resp, true);
  if (!is_array($json)) throw new Exception("Invalid JSON response (HTTP {$code})");
  if ($code >= 400 || empty($json['success'])) {
    $e = isset($json['errors']) ? json_encode($json['errors']) : $resp;
    throw new Exception("Cloudflare API failed (HTTP {$code}): {$e}");
  }
  return $json;
}

function get_public_ip() {
  $sources = [
    "https://api.ipify.org",
    "https://checkip.amazonaws.com",
  ];
  foreach ($sources as $u) {
    $ctx = stream_context_create([
      'http' => ['timeout' => 5],
      'ssl'  => ['verify_peer' => true, 'verify_peer_name' => true],
    ]);
    $ip = @trim(file_get_contents($u, false, $ctx));
    if (filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) return $ip;
  }
  throw new Exception("Could not determine public IPv4");
}

// --- lock ---
$fp = fopen($LOCK, 'c');
if (!$fp || !flock($fp, LOCK_EX | LOCK_NB)) exit(0);

try {
  $ip = get_public_ip();
  
  // Zone ID
  $z = http_json("GET", "https://api.cloudflare.com/client/v4/zones?name=" . urlencode($ZONE_NAME), $CF_TOKEN);
  $zone_id = $z['result'][0]['id'] ?? null;
  if (!$zone_id) throw new Exception("Zone not found: {$ZONE_NAME}");
  
  // Record lookup
  $r = http_json("GET",
    "https://api.cloudflare.com/client/v4/zones/{$zone_id}/dns_records?type=A&name=" . urlencode($RECORD_FQDN),
    $CF_TOKEN
  );
  $rec = $r['result'][0] ?? null;
  if (!$rec) throw new Exception("DNS record not found: {$RECORD_FQDN}");
  
  $current   = $rec['content'] ?? '';
  $record_id = $rec['id'];
  
  // Se não mudou, NÃO loga (pra não inflar)
  if ($current === $ip) exit(0);
  
  // Update record
  $payload = [
    "type" => "A",
    "name" => $RECORD_FQDN,
    "content" => $ip,
    "ttl" => $TTL,
    "proxied" => $PROXIED,
  ];
  http_json("PUT",
    "https://api.cloudflare.com/client/v4/zones/{$zone_id}/dns_records/{$record_id}",
    $CF_TOKEN,
    $payload
  );
  
  logmsg("UPDATED {$RECORD_FQDN}: {$current} -> {$ip}");
  
} catch (Exception $e) {
  logmsg("ERROR {$RECORD_FQDN}: " . $e->getMessage());
  exit(2);
} finally {
  flock($fp, LOCK_UN);
  fclose($fp);
}
EOFPHP

echo "✅ Arquivo PHP criado com sucesso!"

# Passo 3: Definir permissões corretas
chmod 755 "$PHP_SCRIPT"
echo "✅ Permissões definidas (755)"

# Passo 4: Testar o script
echo ""
echo "🧪 Testando execução do script..."
if /usr/local/bin/php -f "$PHP_SCRIPT"; then
    echo "✅ Script executado com sucesso!"
else
    echo "⚠️  Script executou com avisos/erros. Verifique o log em $LOG_FILE"
fi

# Passo 5: Instruções para configurar o Cron
echo ""
echo "=========================================="
echo "📋 PRÓXIMO PASSO: Configurar o Cron Job"
echo "=========================================="
echo ""
echo "Acesse a interface web do pfSense e vá para:"
echo "Services > Cron > Add"
echo ""
echo "Configure da seguinte forma:"
echo ""
echo "Minute:           */2"
echo "Hour:             *"
echo "Day of Month:     *"
echo "Month of Year:    *"
echo "Day of Week:      *"
echo "User:             root"
echo "Command:          /usr/local/bin/php -f /conf/cf_ddns.php"
echo ""
echo "Depois clique em 'Save'"
echo ""
echo "=========================================="
echo "✅ Instalação concluída!"
echo "=========================================="
echo ""
echo "O script irá:"
echo "- Verificar seu IP público a cada 2 minutos"
echo "- Atualizar o registro DNS '$RECORD_FQDN' automaticamente"
echo "- Manter logs em $LOG_FILE"
echo "- Rotacionar logs automaticamente (máx 512KB)"
echo ""
echo "Para verificar o funcionamento:"
echo "  tail -f $LOG_FILE"
echo ""
