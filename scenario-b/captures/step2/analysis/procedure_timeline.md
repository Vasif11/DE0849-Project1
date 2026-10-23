|   t [ms] | interface    | from   | to          | message                                                                                                             |
|---------:|:-------------|:-------|:------------|:--------------------------------------------------------------------------------------------------------------------|
|      0   | N2 NGAP/SCTP | gNB    | AMF         | InitialUEMessage, Registration request [RRCEstablishmentCause=mo-Signalling]                                        |
|      5.7 | SBI HTTP/2   | AMF    | SCP → AUSF  | POST /nausf-auth/v1/ue-authentications → n/d                                                                        |
|     17.3 | SBI HTTP/2   | AUSF   | SCP → UDM   | POST /nudm-ueau/v1/suci-0-001-01-0000-0-0-0000000001/security-information/generate-auth-data → 200                  |
|     20.4 | SBI HTTP/2   | UDM    | SCP → UDR   | GET /nudr-dr/v1/subscription-data/imsi-001010000000001/authentication-data/authentication-subscription → 200        |
|     35.9 | N2 NGAP/SCTP | AMF    | gNB         | DownlinkNASTransport, Authentication request                                                                        |
|     37.6 | N2 NGAP/SCTP | gNB    | AMF         | UplinkNASTransport, Authentication response                                                                         |
|     38   | SBI HTTP/2   | AMF    | SCP → AUSF* | PUT /nausf-auth/v1/ue-authentications/5/5g-aka-confirmation → 200                                                   |
|     38.7 | SBI HTTP/2   | AUSF   | SCP → UDM   | POST /nudm-ueau/v1/imsi-001010000000001/auth-events → n/d                                                           |
|     48   | N2 NGAP/SCTP | AMF    | gNB         | DownlinkNASTransport, Security mode command                                                                         |
|     49.2 | N2 NGAP/SCTP | gNB    | AMF         | UplinkNASTransport, Security mode complete, Registration request                                                    |
|     49.8 | SBI HTTP/2   | AMF    | SCP → UDM*  | PUT /nudm-uecm/v1/imsi-001010000000001/registrations/amf-3gpp-access → 200                                          |
|     52.3 | SBI HTTP/2   | AMF    | SCP → UDM   | GET /nudm-sdm/v2/imsi-001010000000001/am-data → 200                                                                 |
|     52.7 | SBI HTTP/2   | UDM    | SCP → UDR   | GET /nudr-dr/v1/subscription-data/imsi-001010000000001/00101/provisioned-data/am-data → 200                         |
|     54.6 | SBI HTTP/2   | AMF    | SCP → UDM   | GET /nudm-sdm/v2/imsi-001010000000001/smf-select-data → 200                                                         |
|     54.9 | SBI HTTP/2   | UDM    | SCP → UDR   | GET /nudr-dr/v1/subscription-data/imsi-001010000000001/00101/provisioned-data/smf-selection-subscription-data → 200 |
|     56.3 | SBI HTTP/2   | AMF    | SCP → UDM   | GET /nudm-sdm/v2/imsi-001010000000001/ue-context-in-smf-data → 200                                                  |
|     57.1 | SBI HTTP/2   | AMF    | SCP → UDM   | POST /nudm-sdm/v2/imsi-001010000000001/sdm-subscriptions → n/d                                                      |
|     58.5 | SBI HTTP/2   | AMF    | SCP → PCF   | POST /npcf-am-policy-control/v1/policies → n/d                                                                      |
|     64.2 | SBI HTTP/2   | PCF    | SCP → UDR   | GET /nudr-dr/v1/policy-data/ues/imsi-001010000000001/am-data → 200                                                  |
|     69.2 | N2 NGAP/SCTP | AMF    | gNB         | InitialContextSetupRequest, Registration accept                                                                     |
|     69.9 | N2 NGAP/SCTP | gNB    | AMF         | InitialContextSetupResponse                                                                                         |
|    273   | N2 NGAP/SCTP | gNB    | AMF         | UplinkNASTransport, Registration complete, UplinkNASTransport, UL NAS transport, PDU session establishment request  |
|    273.6 | N2 NGAP/SCTP | AMF    | gNB         | DownlinkNASTransport, Configuration update command                                                                  |
|    274.5 | SBI HTTP/2   | AMF    | SCP → SMF   | POST /nsmf-pdusession/v1/sm-contexts → n/d                                                                          |
|    281.4 | SBI HTTP/2   | SMF    | SCP → UDM   | GET /nudm-sdm/v2/imsi-001010000000001/sm-data → 200                                                                 |
|    281.9 | SBI HTTP/2   | UDM    | SCP → UDR   | GET /nudr-dr/v1/subscription-data/imsi-001010000000001/00101/provisioned-data/sm-data → 200                         |
|    284.8 | SBI HTTP/2   | SMF    | SCP → UDM   | POST /nudm-sdm/v2/imsi-001010000000001/sdm-subscriptions → n/d                                                      |
|    286.1 | SBI HTTP/2   | SMF    | SCP → PCF   | POST /npcf-smpolicycontrol/v1/sm-policies → n/d                                                                     |
|    287.1 | SBI HTTP/2   | PCF    | SCP → UDR   | GET /nudr-dr/v1/policy-data/ues/imsi-001010000000001/sm-data → 200                                                  |
|    288.8 | SBI HTTP/2   | PCF    | SCP → BSF   | POST /nbsf-management/v1/pcfBindings → n/d                                                                          |
|    299   | N4 PFCP/UDP  | SMF    | UPF         | PFCP Session Establishment Request                                                                                  |
|    301.5 | N4 PFCP/UDP  | UPF    | SMF         | PFCP Session Establishment Response                                                                                 |
|    303.6 | SBI HTTP/2   | SMF    | SCP → AMF   | POST /namf-comm/v1/ue-contexts/imsi-001010000000001/n1-n2-messages → 200                                            |
|    305.1 | N2 NGAP/SCTP | AMF    | gNB         | PDUSessionResourceSetupRequest, DL NAS transport, PDU session establishment accept                                  |
|    308.4 | N2 NGAP/SCTP | gNB    | AMF         | PDUSessionResourceSetupResponse                                                                                     |
|    309.4 | SBI HTTP/2   | AMF    | SCP → SMF   | POST /nsmf-pdusession/v1/sm-contexts/11/modify → 204                                                                |
|    313.2 | N4 PFCP/UDP  | SMF    | UPF         | PFCP Session Modification Request                                                                                   |
|    313.7 | N4 PFCP/UDP  | UPF    | SMF         | PFCP Session Modification Response                                                                                  |
|    314.3 | SBI HTTP/2   | SMF    | SCP → UDM*  | PUT /nudm-uecm/v1/imsi-001010000000001/registrations/smf-registrations/1 → 200                                      |