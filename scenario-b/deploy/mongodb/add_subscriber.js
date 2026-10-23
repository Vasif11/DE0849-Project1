// Provision the test subscriber in the Open5GS database (same document format as open5gs-dbctl).
// Usage: mongosh mongodb://10.20.4.20/open5gs add_subscriber.js
const imsi = "001010000000001";
db.subscribers.deleteMany({ imsi: imsi });
db.subscribers.insertOne({
  schema_version: NumberInt(1),
  imsi: imsi,
  msisdn: [],
  imeisv: [],
  mme_host: [],
  mme_realm: [],
  purge_flag: [],
  security: {
    k: "465B5CE8B199B49FAA5F0A2EE238A6BC",
    op: null,
    opc: "E8ED289DEBA952E4283B54E88E6183CA",
    amf: "8000",
    sqn: NumberLong(64)
  },
  ambr: { downlink: { value: NumberInt(1), unit: NumberInt(3) }, uplink: { value: NumberInt(1), unit: NumberInt(3) } },
  slice: [{
    sst: NumberInt(1),
    default_indicator: true,
    session: [{
      name: "internet",
      type: NumberInt(1),              // IPv4
      qos: { index: NumberInt(9), arp: { priority_level: NumberInt(8), pre_emption_capability: NumberInt(1), pre_emption_vulnerability: NumberInt(1) } },
      ambr: { downlink: { value: NumberInt(1), unit: NumberInt(3) }, uplink: { value: NumberInt(1), unit: NumberInt(3) } },  // 1 Gbps
      pcc_rule: []
    }]
  }],
  access_restriction_data: NumberInt(32),
  subscriber_status: NumberInt(0),
  operator_determined_barring: NumberInt(0),
  network_access_mode: NumberInt(0),
  subscribed_rau_tau_timer: NumberInt(12),
  __v: NumberInt(0)
});
printjson(db.subscribers.find({ imsi: imsi }, { _id: 0, imsi: 1, "security.k": 1, "slice.session.name": 1 }).toArray());
