function generate_cert_config() {
  local component=$1
  local extensions=${2:-}
  info "generating cert config for component '$component' with ext: '${extensions}'"
  if [ "$extensions" != "" ]; then
    cat <<EOF > "${WORKING_DIR}/${component}.conf"
[ req ]
default_bits = 4096
prompt = no
encrypt_key = yes
default_md = sha512
distinguished_name = dn
req_extensions = req_ext
[ dn ]
CN = ${component}
OU = OpenShift
O = Logging
[ req_ext ]
subjectAltName = ${extensions}
EOF
  else
    cat <<EOF > "${WORKING_DIR}/${component}.conf"
[ req ]
default_bits = 4096
prompt = no
encrypt_key = yes
default_md = sha512
distinguished_name = dn
[ dn ]
CN = ${component}
OU = OpenShift
O = Logging
EOF
  fi
}

function generate_request() {
  local component=$1
  info "signing request for component: $component"
  openssl req -new                                        \
          -out ${WORKING_DIR}/${component}.csr            \
          -newkey rsa:4096                                \
          -keyout ${WORKING_DIR}/${component}.key         \
          -config ${WORKING_DIR}/${component}.conf        \
          -days 712                                       \
          -nodes
}

function sign_cert() {
  local component=$1
  info "Signing cert for component: $component"
  openssl ca \
          -in ${WORKING_DIR}/${component}.csr  \
          -notext                              \
          -out ${WORKING_DIR}/${component}.crt \
          -config ${WORKING_DIR}/signing.conf  \
          -extensions v3_req                   \
          -batch                               \
          -extensions server_ext
}

function generate_certs() {
  local component=$1
  local extensions=${2:-}
  local fileExists=$(test -f ${WORKING_DIR}/${component}.crt;echo $?)
  if [ "$fileExists" == "1" ] ; then
    info "${WORKING_DIR}/${component}.crt" "Regenerate" "FileMissing"
  fi
  local filetype=$(file -b ${WORKING_DIR}/${component}.crt)
  if [ "$fileExists" == "0" ] && [ "$filetype" != "PEM certificate" ] ; then
    info "${WORKING_DIR}/${component}.crt '$filetype' != 'PEM certificate'" "Regenerate" "InvalidFileType"
  fi
  if ! $(openssl x509 -checkend 0 -noout -in ${WORKING_DIR}/${component}.crt > /dev/null 2>&1); then
    info "${WORKING_DIR}/${component}.crt" "Regenerate" "ExpiredOrMissing"
	fi
	info "Generating certs for ${component} with ext: ${extensions}"
	generate_cert_config $component $extensions
	generate_request $component
	sign_cert $component
}

generate_certs $2
