const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");
const https = require("https");
const querystring = require("querystring");

admin.initializeApp();

/**
 * Sends an HTTPS POST request with form-urlencoded data.
 * @param {string} url
 * @param {Object} formData
 * @return {Promise<{statusCode: number, body: string}>}
 */
function postForm(url, formData) {
  return new Promise((resolve, reject) => {
    const body = querystring.stringify(formData);
    const requestUrl = new URL(url);

    const req = https.request(
        {
          hostname: requestUrl.hostname,
          path: requestUrl.pathname,
          method: "POST",
          headers: {
            "Content-Type": "application/x-www-form-urlencoded",
            "Content-Length": Buffer.byteLength(body),
          },
        },
        (res) => {
          let data = "";
          res.on("data", (chunk) => {
            data += chunk;
          });
          res.on("end", () => {
            resolve({
              statusCode: res.statusCode,
              body: data,
            });
          });
        },
    );

    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

/**
 * Sends an HTTPS POST request with JSON data.
 * @param {string} url
 * @param {Object} jsonData
 * @param {string} accessToken
 * @return {Promise<{statusCode: number, body: string}>}
 */
function postJson(url, jsonData, accessToken) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify(jsonData);
    const requestUrl = new URL(url);

    const req = https.request(
        {
          hostname: requestUrl.hostname,
          path: requestUrl.pathname,
          method: "POST",
          headers: {
            "Authorization": `Bearer ${accessToken}`,
            "Content-Type": "application/json",
            "Accept": "application/json",
            "X-Amzn-Type-Version":
              "com.amazon.device.messaging.ADMMessage@1.0",
            "X-Amzn-Accept-Type":
              "com.amazon.device.messaging.ADMSendResult@1.0",
            "Content-Length": Buffer.byteLength(body),
          },
        },
        (res) => {
          let data = "";
          res.on("data", (chunk) => {
            data += chunk;
          });
          res.on("end", () => {
            resolve({
              statusCode: res.statusCode,
              body: data,
            });
          });
        },
    );

    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

/**
 * Gets an ADM access token using Amazon credentials
 * saved in environment variables.
 * @return {Promise<string>}
 */
async function getAdmAccessToken() {
  const clientId = process.env.ADM_CLIENT_ID;
  const clientSecret = process.env.ADM_CLIENT_SECRET;

  if (!clientId || !clientSecret) {
    throw new Error(
        "ADM_CLIENT_ID or ADM_CLIENT_SECRET is missing " +
        "in environment variables.",
    );
  }

  const tokenResponse = await postForm(
      "https://api.amazon.com/auth/O2/token",
      {
        grant_type: "client_credentials",
        scope: "messaging:push",
        client_id: clientId,
        client_secret: clientSecret,
      },
  );

  if (tokenResponse.statusCode !== 200) {
    throw new Error(
        `Failed to get ADM access token: ${tokenResponse.body}`,
    );
  }

  const parsed = JSON.parse(tokenResponse.body);
  return parsed.access_token;
}

exports.sendAdmTestNotification = functions.https.onRequest(
    async (req, res) => {
      try {
        const uid = req.query.uid;

        if (!uid) {
          res.status(400).send("Missing uid query parameter.");
          return;
        }

        const db = admin.firestore();
        const deviceDoc = await db
            .collection("device_registrations")
            .doc(uid)
            .get();

        if (!deviceDoc.exists) {
          res.status(404).send("No device registration found for that uid.");
          return;
        }

        const deviceData = deviceDoc.data();
        const admToken = deviceData.admToken;

        if (!admToken) {
          res
              .status(400)
              .send("This device registration has no admToken.");
          return;
        }

        const accessToken = await getAdmAccessToken();

        const admResponse = await postJson(
            "https://api.amazon.com/messaging/registrations/" +
            `${admToken}/messages`,
            {
              data: {
                title: "KTB Backend Test",
                body: "This notification was sent from Firebase Functions.",
              },
              priority: "high",
              expiresAfter: 3600,
            },
            accessToken,
        );

        res.status(200).send({
          success: true,
          uid: uid,
          admStatusCode: admResponse.statusCode,
          admResponseBody: admResponse.body,
        });
      } catch (error) {
        console.error("sendAdmTestNotification error:", error);
        res.status(500).send({
          success: false,
          error: error.message,
        });
      }
    },
);

exports.generateDailyNudges = functions.pubsub
    .schedule("every 24 hours")
    .timeZone("America/Denver")
    .onRun(async () => {
      const db = admin.firestore();

      const familiesSnapshot = await db.collection("families").get();

      for (const familyDoc of familiesSnapshot.docs) {
        const familyId = familyDoc.id;

        const accountsSnapshot = await db
            .collection("families")
            .doc(familyId)
            .collection("accounts")
            .get();

        for (const account of accountsSnapshot.docs) {
          const data = account.data();
          const role = data.role;

          const prompt = role === "child" ?
            "Did anything online today make you feel happy or upset?" :
            "Did you notice anything about your child's technology use today?";

          await db
              .collection("families")
              .doc(familyId)
              .collection("nudges")
              .add({
                prompt: prompt,
                targetAccountId: account.id,
                targetRole: role,
                status: "pending",
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
                scheduledFor: admin.firestore.FieldValue.serverTimestamp(),
              });
        }
      }

      console.log("Daily nudges created for all families");
      return null;
    });

exports.generateTestNudges = functions.https.onRequest(async (req, res) => {
  const db = admin.firestore();

  const familiesSnapshot = await db.collection("families").get();

  for (const familyDoc of familiesSnapshot.docs) {
    const familyId = familyDoc.id;

    const accountsSnapshot = await db
        .collection("families")
        .doc(familyId)
        .collection("accounts")
        .get();

    for (const account of accountsSnapshot.docs) {
      const data = account.data();
      const role = data.role;

      const prompt = role === "child" ?
        "What was the most interesting thing you did online today?" :
        "Did you notice anything positive about your child's tech use today?";

      await db
          .collection("families")
          .doc(familyId)
          .collection("nudges")
          .add({
            prompt: prompt,
            targetAccountId: account.id,
            targetRole: role,
            status: "pending",
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            scheduledFor: admin.firestore.FieldValue.serverTimestamp(),
          });
    }
  }

  res.send("Test nudges generated");
});
