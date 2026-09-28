#!/bin/sh
# Creates a self-signed code-signing identity and imports it into the login keychain.
#
#   scripts/signing-cert.sh NAME [P12_OUT]
#
# It need not be trusted: codesign only needs the key, and TCC matches on the
# certificate hash, so Accessibility grants survive every build signed with it. With
# P12_OUT, the identity is also kept as a password-protected .p12 so CI can sign with
# the same certificate, and the password is printed.
set -eu

name=$1
out=${2:-}

if security find-identity -p codesigning | grep -q "\"$name\""; then
	echo "'$name' already exists in the keychain"
	[ -z "$out" ] || [ -f "$out" ] || echo "note: $out not found; export it from Keychain Access if CI needs it"
	exit 0
fi

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
pass=$(openssl rand -hex 16)

printf '[req]\ndistinguished_name=dn\nprompt=no\nx509_extensions=ext\n[dn]\nCN=%s\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' \
	"$name" > "$dir/cnf"
# Ten years: the certificate is what users' Accessibility grants are tied to, so
# replacing it means every user re-grants once.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
	-keyout "$dir/key.pem" -out "$dir/cert.pem" -config "$dir/cnf" 2>/dev/null
# -legacy: the Security framework cannot read OpenSSL 3's default p12 encryption.
openssl pkcs12 -export -legacy -inkey "$dir/key.pem" -in "$dir/cert.pem" \
	-name "$name" -out "$dir/id.p12" -passout "pass:$pass"
security import "$dir/id.p12" -k ~/Library/Keychains/login.keychain-db -P "$pass" -T /usr/bin/codesign
echo "created '$name'"

if [ -n "$out" ]; then
	mkdir -p "$(dirname "$out")"
	cp "$dir/id.p12" "$out"
	echo
	echo "Exported to $out, password: $pass"
	echo "Back both up somewhere safe. Losing them means every user re-grants Accessibility."
	echo "To let CI sign releases:"
	echo "  base64 -i $out | gh secret set RELEASE_CERT_P12"
	echo "  gh secret set RELEASE_CERT_PASSWORD --body $pass"
fi
