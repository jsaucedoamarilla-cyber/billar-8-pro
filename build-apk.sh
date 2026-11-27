#!/usr/bin/env bash
# BILLAR 8 PRO - compilación del APK. Se ejecuta desde la RAÍZ del repositorio:  bash build-apk.sh
# Versión del script: v27
SUM="${GITHUB_STEP_SUMMARY:-/dev/null}"
OUT="${GITHUB_OUTPUT:-/dev/null}"

# ===================== MODO INTERNO: armar y compilar UN intento =====================
# (se ejecuta como proceso aparte para que cualquier error corte de verdad)
if [ "${1:-}" = "--armar" ]; then
  set -euo pipefail
  NAT="$2"
  rm -rf _apk; mkdir -p _apk; cp -a _www _apk/www
  cd _apk
  npm init -y >/dev/null
  npm install @capacitor/core@6 @capacitor/cli@6 @capacitor/android@6
  if [ "$NAT" = 1 ]; then npm install @capacitor-firebase/authentication@6 firebase@10; fi
  if [ "$NAT" = 1 ]; then
    printf '{"appId":"com.billar8pro.app","appName":"Billar 8 Pro","webDir":"www","server":{"androidScheme":"https"},"plugins":{"FirebaseAuthentication":{"skipNativeAuth":true,"providers":%s}}}\n' "$PROVIDERS" > capacitor.config.json
  else
    printf '{"appId":"com.billar8pro.app","appName":"Billar 8 Pro","webDir":"www","server":{"androidScheme":"https"}}\n' > capacitor.config.json
  fi
  npx cap add android
  npx cap sync android
  sed -i "s/versionCode [0-9][0-9]*/versionCode ${GITHUB_RUN_NUMBER:-1}/; s/versionName \"[^\"]*\"/versionName \"${APPV}\"/" android/app/build.gradle
  sed -i 's#</manifest>#<uses-permission android:name="android.permission.RECORD_AUDIO"/><uses-permission android:name="android.permission.CAMERA"/><uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS"/></manifest>#' android/app/src/main/AndroidManifest.xml
  if [ "$NAT" = 1 ]; then
    cp ../google-services.json android/app/google-services.json
    if [ "$FB" = 1 ]; then
      FB_APP_ID="$FB_APP_ID" FB_CLIENT_TOKEN="$FB_CLIENT_TOKEN" python3 - <<'PY'
import os
app_id=os.environ['FB_APP_ID']; token=os.environ['FB_CLIENT_TOKEN']
sp='android/app/src/main/res/values/strings.xml'
t=open(sp,encoding='utf-8').read()
add=('<string name="facebook_app_id">%s</string>\n'
     '<string name="facebook_client_token">%s</string>\n'
     '<string name="fb_login_protocol_scheme">fb%s</string>\n') % (app_id,token,app_id)
open(sp,'w',encoding='utf-8').write(t.replace('</resources>', add+'</resources>'))
mp='android/app/src/main/AndroidManifest.xml'
m=open(mp,encoding='utf-8').read()
meta=('<meta-data android:name="com.facebook.sdk.ApplicationId" android:value="@string/facebook_app_id"/>'
      '<meta-data android:name="com.facebook.sdk.ClientToken" android:value="@string/facebook_client_token"/>')
open(mp,'w',encoding='utf-8').write(m.replace('</application>', meta+'</application>'))
PY
    fi
  fi
  mkdir -p ~/.android; cp ../debug.keystore ~/.android/debug.keystore
  cd android
  chmod +x gradlew
  ./gradlew assembleDebug --no-daemon
  exit 0
fi

# ===================== MODO PRINCIPAL =====================
set -euo pipefail
{ echo "## Build APK · script v27"; echo; echo "### Archivos en la raíz del repositorio"; ls -1 | sed 's/^/- /'; echo; } >> "$SUM"

# 1) Descomprimir TODOS los zip del repositorio (incluso zip dentro de zip), sin depender de los nombres
for nivel in 1 2 3 4; do
  while IFS= read -r -d '' z; do
    d="${z%.zip}_x"
    [ -d "$d" ] && continue
    mkdir -p "$d"; unzip -oq "$z" -d "$d" || true
  done < <(find . \( -path ./_apk -o -path ./_www -o -path ./node_modules -o -path ./.git \) -prune -o -type f -name '*.zip' -print0)
done

# 2) Elegir la versión MÁS ALTA del juego
BEST=""; BESTV=-1
echo "### Versiones del juego encontradas" >> "$SUM"
while IFS= read -r -d '' f; do
  v=$(grep -o "APPV = 'guia-[0-9]*" "$f" | head -1 | grep -o '[0-9]*$' || true); v=${v:-0}
  echo "- \`$f\` → guia-$v" >> "$SUM"
  if [ "$v" -gt "$BESTV" ]; then BESTV=$v; BEST="$f"; fi
done < <(find . \( -path ./_apk -o -path ./_www -o -path ./node_modules -o -path ./.git \) -prune -o -type f -name index.html -path '*JUEGO_BILLAR_8_PRO*' -print0)
if [ -z "$BEST" ]; then echo "::error::No se encontró el juego (carpeta JUEGO_BILLAR_8_PRO con index.html) en el repositorio"; echo "❌ No se encontró el juego en el repositorio" >> "$SUM"; exit 1; fi
SRC=$(dirname "$BEST")
export APPV="guia-$BESTV"
KEYSTORE=$(find . \( -path ./_apk -o -path ./_www -o -path ./node_modules -o -path ./.git \) -prune -o -type f -name debug.keystore -print | head -1 || true)
if [ -z "$KEYSTORE" ]; then echo "::error::No se encontró debug.keystore"; echo "❌ No se encontró debug.keystore" >> "$SUM"; exit 1; fi
[ "$KEYSTORE" = "./debug.keystore" ] || cp "$KEYSTORE" ./debug.keystore
rm -rf _www; mkdir -p _www; cp -a "$SRC"/. _www/
rm -f _www/admin.html _www/reglas_firestore.txt _www/_headers
echo "appv=$APPV" >> "$OUT"
{ echo; echo "### Versión del juego en este APK: **$APPV**"; echo "Fuente: \`$BEST\`"; echo "Firma: \`$KEYSTORE\`"; echo; } >> "$SUM"

# 3) ¿Está bien configurado el acceso nativo con Google/Facebook?
MOTIVO=$(python3 - <<'PY'
import json,os
f='google-services.json'
if not os.path.exists(f):
    print('falta google-services.json en la raíz del repositorio'); raise SystemExit
try:
    d=json.load(open(f,encoding='utf-8'))
except Exception:
    print('google-services.json no es un JSON válido (¿se subió incompleto?)'); raise SystemExit
pk=False; web=False; android=False
for c in d.get('client',[]):
    if c.get('client_info',{}).get('android_client_info',{}).get('package_name')=='com.billar8pro.app':
        pk=True
        for o in c.get('oauth_client',[]):
            if o.get('client_type')==3: web=True
            if o.get('client_type')==1: android=True
if not pk: print('google-services.json no tiene la app com.billar8pro.app (registrala en Firebase y descargalo de nuevo)')
elif not web: print('falta cliente OAuth web tipo 3: habilitá Google en Firebase Authentication y descargá el JSON actualizado')
elif not android: print('falta cliente OAuth Android tipo 1: registrá SHA-1 y SHA-256 en Firebase, y descargá el JSON actualizado')
PY
)
leer() { { [ -f facebook.env ] && sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" facebook.env | head -1 | tr -d '\r"'"'"' ' ; } || true; }
export FB_APP_ID FB_CLIENT_TOKEN
FB_APP_ID=$(leer FB_APP_ID); FB_CLIENT_TOKEN=$(leer FB_CLIENT_TOKEN)
export PROVIDERS='["google.com"]' FB=0
NATIVO=0
# PRUEBA DE ESTABILIDAD: desactivar el plugin Firebase nativo para comprobar
# si es el causante del cierre al abrir. El inicio web/como invitado queda disponible.
if [ -z "$MOTIVO" ]; then
  NATIVO=0
  if [ -n "$FB_APP_ID" ] && [ -n "$FB_CLIENT_TOKEN" ]; then PROVIDERS='["google.com","facebook.com"]'; FB=1; fi
fi

# No forzar NATIVO=0: activar el login nativo solamente si la configuración OAuth
# de Android y Web está completa. Si falta, el APK seguro se compila sin login nativo.

# 4) Compilar (con login nativo si se puede; si falla, se reintenta sin él para tener SIEMPRE un APK)
HECHO=0
if [ "$NATIVO" = 1 ]; then
  if bash "$0" --armar 1 2>&1 | tee gradle_nativo.log; then
    HECHO=1
    echo "✅ Login nativo ACTIVADO: Google$( [ "$FB" = 1 ] && echo ' + Facebook' )" >> "$SUM"
  else
    echo "::warning::Falló la compilación con login nativo; se compila sin él"
    { echo "⚠️ La compilación CON login nativo falló. Se compiló SIN él. Error de Gradle:"; echo '```'; grep -E "error:|Error:|FAILED|What went wrong|Execution failed|No matching client|not found|Could not|Duplicate" -A4 gradle_nativo.log | head -40; echo '```'; } >> "$SUM"
  fi
else
  echo "::warning::Login nativo DESACTIVADO: $MOTIVO"
  echo "⚠️ Login nativo DESACTIVADO: $MOTIVO. La app abre normal y se entra como invitado." >> "$SUM"
fi
if [ "$HECHO" = 0 ]; then
  if ! bash "$0" --armar 0 2>&1 | tee gradle_base.log; then
    { echo "❌ La compilación falló. Error de Gradle:"; echo '```'; grep -E "error:|Error:|FAILED|What went wrong|Execution failed|Could not" -A4 gradle_base.log | head -40; echo '```'; } >> "$SUM"
    exit 1
  fi
fi
mkdir -p _out
cp _apk/android/app/build/outputs/apk/debug/app-debug.apk _out/app-debug.apk
echo "✅ APK listo: $APPV" >> "$SUM"
