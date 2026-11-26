#!/bin/bash
# Compila un proyecto SSDT (legacy) en Linux con un wrapper SDK Microsoft.Build.Sql.
# Uso: build-check.sh <dir-del-sqlproj> <dir-salida>
# Salida: BUILD_EXIT=<n>, y <dir-salida>/errors.txt con los errores (sin rutas absolutas).
# No se conecta a ninguna BD.
set -u
PROJ="$(cd "$1" && pwd)"; OUT="$2"
DOTNET="${DOTNET:-/home/soporte/.dotnet/dotnet}"
export DOTNET_ROOT="$(dirname "$DOTNET")" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
mkdir -p "$OUT"
SQLPROJ=$(ls "$PROJ"/*.sqlproj | head -1)
NAME=$(basename "$SQLPROJ" .sqlproj)
# Version del SDK. 0.1.19-preview no conoce Sql170 y usa un DacFx viejo (ej. EXTERNAL DATA
# SOURCE TYPE=RDBMS queda con otro enum que el de sqlpackage 170 -> diferencias falsas).
MBS_VERSION="${MBS_VERSION:-0.1.19-preview}"
DSP=$(grep -o '<DSP>[^<]*</DSP>' "$SQLPROJ" | sed 's#<DSP>##; s#</DSP>##')
[ -n "$DSP" ] || DSP="Microsoft.Data.Tools.Schema.Sql.Sql160DatabaseSchemaProvider"
case "$MBS_VERSION" in 0.*) case "$DSP" in *Sql170*) DSP="Microsoft.Data.Tools.Schema.Sql.Sql160DatabaseSchemaProvider";; esac;; esac
W="$OUT/wrap"; rm -rf "$W"; mkdir -p "$W"
# Propiedades del modelo que cambian la validacion: se copian del .sqlproj original.
# Sin ModelCollation el SDK valida case-sensitive y da errores falsos (@P_X vs @p_x, SYSNAME).
PROPS=$(grep -oE '<(ModelCollation|DefaultCollation|DefaultSchema|Containment|CompatibilityMode|AnsiNulls|QuotedIdentifier|AnsiPadding|AnsiWarnings|ArithAbort|ConcatNullYieldsNull|NumericRoundAbort|IsNestedTriggersOn|IsTransformNoiseWordsOn|DefaultLanguage|DefaultFullTextLanguage|TwoDigitYearCutoff)>[^<]*</[A-Za-z]+>' "$SQLPROJ" | awk -F'[<>]' '!seen[$2]++')
grep -q '<ModelCollation>' <<<"$PROPS" || PROPS="$PROPS<ModelCollation>1033,CI</ModelCollation>"
{
  echo "<Project Sdk=\"Microsoft.Build.Sql/$MBS_VERSION\">"
  echo '  <PropertyGroup>'
  echo "    <Name>$NAME</Name>"
  echo "    <DSP>$DSP</DSP>"
  printf '%s\n' "$PROPS" | sed 's/^/    /'
  echo '    <EnableDefaultSqlItems>false</EnableDefaultSqlItems>'
  echo '    <SuppressTSqlWarnings>71502;71558;71562</SuppressTSqlWarnings>'
  echo '  </PropertyGroup>'
  echo '  <ItemGroup>'
  # Lista de archivos: excluye CLR y agrega stubs de validacion (ver build-check-items.py)
  python3 "$(dirname "$0")/build-check-items.py" "$PROJ" "$SQLPROJ" "$W" "$OUT" | while IFS= read -r f; do
    printf '    <Build Include="%s" />\n' "$f"
  done
  echo '  </ItemGroup>'
  # Referencia a otra base (bundle): REF_DACPAC=<dacpac compilado>, REF_VAR=<variable SQLCMD>
  if [ -n "${REF_DACPAC:-}" ] && [ -f "$REF_DACPAC" ]; then
    RV="${REF_VAR:-sqldb_core_global}"
    echo '  <ItemGroup>'
    echo "    <ArtifactReference Include=\"$REF_DACPAC\">"
    echo '      <SuppressMissingDependenciesErrors>True</SuppressMissingDependenciesErrors>'
    echo "      <DatabaseSqlCmdVariable>$RV</DatabaseSqlCmdVariable>"
    echo '    </ArtifactReference>'
    echo "    <SqlCmdVariable Include=\"$RV\"><DefaultValue>$RV</DefaultValue><Value>$RV</Value></SqlCmdVariable>"
    echo '  </ItemGroup>'
  fi
  echo '</Project>'
} > "$W/$NAME.sqlproj"
timeout 1500 "$DOTNET" build "$W/$NAME.sqlproj" -nologo -v:q -o "$OUT/bin" > "$OUT/build.log" 2>&1
RC=$?
grep -E "Build error SQL|error MSB|error NU" "$OUT/build.log" | sed "s#$PROJ/##g; s# \[$W/[^]]*\]##" | sort -u > "$OUT/errors.txt"
echo "BUILD_EXIT=$RC"
echo "BUILD_ERRORS=$(wc -l < "$OUT/errors.txt")"
exit $RC
