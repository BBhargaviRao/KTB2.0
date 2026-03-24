const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");
const https = require("https");
const querystring = require("querystring");
const OpenAI = require("openai");
const {defineSecret} = require("firebase-functions/params");

const openaiApiKey = defineSecret("OPENAI_API_KEY");

admin.initializeApp();

exports.testOpenAI = functions
    .runWith({secrets: ["OPENAI_API_KEY"]})
    .https.onRequest(async (req, res) => {
      try {
        const client = new OpenAI({
          apiKey: openaiApiKey.value(),
        });

        const response = await client.chat.completions.create({
          model: "gpt-4o-mini",
          messages: [
            {role: "user", content: "Say hello in 5 words."},
          ],
        });

        const text = response.choices[0].message.content;

        res.send({success: true, text});
      } catch (err) {
        console.error(err);
        res.status(500).send({error: err.message});
      }
    });

exports.testLatestChildResponse = functions.https.onRequest(
    async (req, res) => {
      try {
        const familyId = req.query.familyId;

        if (!familyId) {
          return res.status(400).send({
            error: "Missing familyId",
          });
        }

        const now = new Date();
        const startOfDay = new Date(now);
        startOfDay.setHours(0, 0, 0, 0);

        const nudgesSnap = await admin.firestore()
            .collection("families")
            .doc(familyId)
            .collection("nudges")
            .where("targetRole", "==", "child")
            .where("status", "==", "answered")
            .where(
                "createdAt",
                ">=",
                admin.firestore.Timestamp.fromDate(startOfDay),
            )
            .orderBy("createdAt", "desc")
            .limit(1)
            .get();

        if (nudgesSnap.empty) {
          return res.send({
            success: true,
            found: false,
            message: "No answered child nudges found for today.",
          });
        }

        const doc = nudgesSnap.docs[0];
        const data = doc.data();

        return res.send({
          success: true,
          found: true,
          nudgeId: doc.id,
          responseText: data.response && data.response.text ?
            data.response.text :
            null,
          deliveryWindow: data.deliveryWindow || null,
          createdAt: data.createdAt || null,
          shareWithParent: data.shareWithParent || false,
        });
      } catch (err) {
        console.error(err);
        return res.status(500).send({
          error: err.message,
        });
      }
    },
);

exports.testGenerateParentPrompt = functions
    .runWith({secrets: ["OPENAI_API_KEY"]})
    .https.onRequest(async (req, res) => {
      try {
        const childText = req.query.text;

        if (!childText) {
          return res.status(400).send({
            error: "Missing ?text= query param",
          });
        }

        const client = new OpenAI({
          apiKey: openaiApiKey.value(),
        });

        const response = await client.chat.completions.create({
          model: "gpt-4o-mini",
          messages: [
            {
              role: "system",
              content: `
You create a SHORT PARENT NUDGE for a parent,
based on a child's private digital experience.

The child’s exact words are private input only.
Never reveal specific details, events, or quotes.

Your goal:
- Help the parent gently connect with their child
- Encourage trust, conversation, and emotional awareness
- Reflect whether the child’s DIGITAL experience
  was likely positive or challenging
- Keep the tone warm, natural, and human

Guidelines:
- If the child experience seems challenging:
  → encourage a gentle emotional check-in
- If it seems positive:
  → encourage curiosity and sharing
- If unclear:
  → keep it neutral but still connection-focused
- Keep the nudge subtly grounded in digital or online experiences 
  (without revealing specifics)

Rules:
- The nudge is for the PARENT
- Do NOT advise the child
- Do NOT reveal specifics
- Do NOT mention platforms, games, or events
- Do NOT quote the child
- Do NOT sound clinical or robotic
- Ask ONE natural parent-facing question
- Max 20 words

Write like a real app nudge:
short, warm, and easy to act on

Return JSON only:
{
  "contextType": "positive | challenging | neutral",
  "parentPrompt": "..."
}
              `,
            },
            {
              role: "user",
              content: childText,
            },
          ],
        });

        const text = response.choices[0].message.content;

        return res.send({
          success: true,
          raw: text,
        });
      } catch (err) {
        console.error(err);
        return res.status(500).send({
          error: err.message,
        });
      }
    });

/**
 * Gets the latest answered child response for today.
 * @param {string} familyId
 * @return {Promise<{nudgeId: string, text: ?string}|null>}
 */
async function getLatestChildResponse(familyId) {
  const now = new Date();
  const startOfDay = new Date(now);
  startOfDay.setHours(0, 0, 0, 0);

  const nudgesSnap = await admin.firestore()
      .collection("families")
      .doc(familyId)
      .collection("nudges")
      .where("targetRole", "==", "child")
      .where("status", "==", "answered")
      .where(
          "createdAt",
          ">=",
          admin.firestore.Timestamp.fromDate(startOfDay),
      )
      .orderBy("createdAt", "desc")
      .limit(1)
      .get();

  if (nudgesSnap.empty) {
    return null;
  }

  const doc = nudgesSnap.docs[0];
  const data = doc.data();

  return {
    nudgeId: doc.id,
    text: data.response && data.response.text ?
      data.response.text :
      null,
  };
}

/**
 * Generates a parent-safe nudge from a child's response.
 * @param {string} childText
 * @return {Promise<{contextType: string, parentPrompt: string}|null>}
 */
async function generateParentPromptFromChildText(childText) {
  if (!childText) {
    return null;
  }

  const client = new OpenAI({
    apiKey: openaiApiKey.value(),
  });

  const response = await client.chat.completions.create({
    model: "gpt-4o-mini",
    messages: [
      {
        role: "system",
        content: `
You create a SHORT PARENT NUDGE for a parent,
based on a child's private digital experience.

The child’s exact words are private input only.
Never reveal specific details, events, or quotes.

Your goal:
- Help the parent gently connect with their child
- Encourage trust, conversation, and emotional awareness
- Reflect whether the child’s DIGITAL experience
  was likely positive or challenging
- Keep the tone warm, natural, and human

Guidelines:
- If the child experience seems challenging:
  → encourage a gentle emotional check-in
- If it seems positive:
  → encourage curiosity and sharing
- If unclear:
  → keep it neutral but still connection-focused
- Keep the nudge subtly grounded in digital or online 
  experiences (without revealing specifics)

Rules:
- The nudge is for the PARENT
- Do NOT advise the child
- Do NOT reveal specifics
- Do NOT mention platforms, games, or events
- Do NOT quote the child
- Do NOT sound clinical or robotic
- Ask ONE natural parent-facing question
- Max 20 words

Write like a real app nudge:
short, warm, and easy to act on

Return JSON only:
{
  "contextType": "positive | challenging | neutral",
  "parentPrompt": "..."
}
        `,
      },
      {
        role: "user",
        content: childText,
      },
    ],
  });

  const raw = response.choices[0].message.content;
  const parsed = JSON.parse(raw);

  if (!parsed.parentPrompt) {
    return null;
  }

  return {
    contextType: parsed.contextType || "neutral",
    parentPrompt: parsed.parentPrompt,
  };
}

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

/**
 * Central structured prompt library.
 * Each prompt has stable research-ready metadata.
 * @return {Object}
 */
function getPromptBank() {
  return {
    parent_morning: [
      {
        id: "parent_morning_1",
        category: "parent_morning_check_in",
        variant: "emotion_guess",
        source: "library",
        text:
          "How do you think your child is feeling about technology " +
          "so far today?",
      },
      {
        id: "parent_morning_2",
        category: "parent_morning_check_in",
        variant: "positive_curiosity",
        source: "library",
        text:
          "What do you think your child is enjoying most about " +
          "technology today?",
      },
      {
        id: "parent_morning_3",
        category: "parent_morning_check_in",
        variant: "attention_reflection",
        source: "library",
        text:
          "How connected or distracted does your child seem with " +
          "technology today?",
      },
      {
        id: "parent_morning_4",
        category: "parent_morning_check_in",
        variant: "parent_observation",
        source: "library",
        text:
          "Is there anything about your child's tech use so far today " +
          "that you are wondering about?",
      },
    ],

    child_afternoon: [
      {
        id: "child_afternoon_1",
        category: "child_afternoon_check_in",
        variant: "emotion_check",
        source: "library",
        text: "How are you feeling about your screen time today?",
      },
      {
        id: "child_afternoon_2",
        category: "child_afternoon_check_in",
        variant: "positive_or_frustrating",
        source: "library",
        text: "Has anything online felt fun or frustrating today?",
      },
      {
        id: "child_afternoon_3",
        category: "child_afternoon_check_in",
        variant: "activity_reflection",
        source: "library",
        text:
          "What kind of screen activity has stood out to you today?",
      },
      {
        id: "child_afternoon_4",
        category: "child_afternoon_check_in",
        variant: "open_reflection",
        source: "library",
        text:
          "What is something interesting, fun, or annoying that " +
          "happened online today?",
      },
    ],

    parent_evening: [
      {
        id: "parent_evening_1",
        category: "parent_evening_reflection",
        variant: "general_observation",
        source: "library",
        text:
          "Did you notice anything about your child's technology use " +
          "today?",
      },
      {
        id: "parent_evening_2",
        category: "parent_evening_reflection",
        variant: "engaged_or_frustrated",
        source: "library",
        text:
          "Was there a moment today when your child seemed engaged " +
          "or frustrated with screens?",
      },
      {
        id: "parent_evening_3",
        category: "parent_evening_reflection",
        variant: "parent_reflection",
        source: "library",
        text:
          "Did anything about today's tech use stand out to you as " +
          "a parent?",
      },
      {
        id: "parent_evening_4",
        category: "parent_evening_reflection",
        variant: "positive_or_challenging",
        source: "library",
        text:
          "Did you notice anything positive or challenging about " +
          "your child's screen time today?",
      },
    ],

    child_night: [
      {
        id: "child_night_1",
        category: "child_night_reflection",
        variant: "good_or_difficult",
        source: "library",
        text:
          "What was one good or difficult thing about your screen " +
          "time today?",
      },
      {
        id: "child_night_2",
        category: "child_night_reflection",
        variant: "most_interesting",
        source: "library",
        text:
          "What was the most interesting thing you did online today?",
      },
      {
        id: "child_night_3",
        category: "child_night_reflection",
        variant: "emotion_reflection",
        source: "library",
        text:
          "Was there anything online today that made you feel really " +
          "good or not so good?",
      },
      {
        id: "child_night_4",
        category: "child_night_reflection",
        variant: "remember_or_talk",
        source: "library",
        text:
          "What is one thing about your screen time today that you " +
          "want to remember or talk about?",
      },
    ],
  };
}

/**
 * Returns one random item from an array.
 * @param {Array} items
 * @return {*|null}
 */
function pickRandom(items) {
  if (!items || !items.length) {
    return null;
  }

  const index = Math.floor(Math.random() * items.length);
  return items[index];
}

/**
 * Picks a prompt for a delivery window while avoiding
 * repeating the same prompt for the same account twice in a row.
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} familyId
 * @param {string} accountId
 * @param {string} deliveryWindow
 * @return {Promise<{id: string, text: string}|null>}
 */
async function pickPromptForAccount(
    db,
    familyId,
    accountId,
    deliveryWindow,
) {
  const promptBank = getPromptBank();
  const prompts = promptBank[deliveryWindow] || [];

  if (!prompts.length) {
    return null;
  }

  const latestSnapshot = await db
      .collection("families")
      .doc(familyId)
      .collection("nudges")
      .where("targetAccountId", "==", accountId)
      .where("deliveryWindow", "==", deliveryWindow)
      .orderBy("createdAt", "desc")
      .limit(1)
      .get();

  let lastPromptId = null;

  if (!latestSnapshot.empty) {
    const latestData = latestSnapshot.docs[0].data();
    lastPromptId = latestData.promptId || null;
  }

  let eligiblePrompts = prompts;

  if (lastPromptId) {
    const filtered = prompts.filter((prompt) => prompt.id !== lastPromptId);

    if (filtered.length > 0) {
      eligiblePrompts = filtered;
    }
  }

  return pickRandom(eligiblePrompts);
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

exports.generateDailyNudges = functions
    .runWith({secrets: ["OPENAI_API_KEY"]})
    .pubsub.schedule("every 30 minutes")
    .timeZone("America/Denver")
    .onRun(async () => {
      const db = admin.firestore();
      const now = new Date();
      const hour = now.getHours();
      const dateKey = now.toISOString().split("T")[0];

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

          let nudgeType = null;
          let deliveryWindow = null;
          let selectedPrompt = null;

          if (role === "parent" && hour >= 8 && hour < 11) {
            nudgeType = "check_in";
            deliveryWindow = "parent_morning";
          } else if (role === "child" && hour >= 13 && hour < 16) {
            nudgeType = "check_in";
            deliveryWindow = "child_afternoon";
          } else if (role === "parent" && hour >= 18 && hour < 21) {
            nudgeType = "reflection";
            deliveryWindow = "parent_evening";
          } else if (role === "child" && hour >= 19 && hour < 21) {
            nudgeType = "reflection";
            deliveryWindow = "child_night";
          } else {
            continue;
          }

          selectedPrompt = await pickPromptForAccount(
              db,
              familyId,
              account.id,
              deliveryWindow,
          );

          let finalPrompt = selectedPrompt.text;
          let finalPromptCategory = selectedPrompt.category;
          let promptGenerationMode = "library";

          if (role === "parent" && deliveryWindow === "parent_evening") {
            try {
              const childData = await getLatestChildResponse(familyId);

              if (childData && childData.text) {
                const result = await generateParentPromptFromChildText(
                    childData.text,
                );

                if (result && result.parentPrompt) {
                  finalPrompt = result.parentPrompt;
                  promptGenerationMode = "llm_context";
                  if (result.contextType === "positive") {
                    finalPromptCategory = "parent_evening_context_positive";
                  } else if (result.contextType === "challenging") {
                    finalPromptCategory = "parent_evening_context_challenging";
                  } else {
                    finalPromptCategory = "parent_evening_context_neutral";
                  }

                  console.log(
                      "Using LLM parent prompt:",
                      finalPrompt,
                      "category:",
                      finalPromptCategory,
                  );
                }
              }
            } catch (err) {
              console.error("LLM fallback to default prompt:", err);
            }
          }

          if (!selectedPrompt) {
            console.log("No prompt found for deliveryWindow:", deliveryWindow);
            continue;
          }

          const existingNudge = await db
              .collection("families")
              .doc(familyId)
              .collection("nudges")
              .where("targetAccountId", "==", account.id)
              .where("deliveryWindow", "==", deliveryWindow)
              .where("dateKey", "==", dateKey)
              .limit(1)
              .get();

          if (!existingNudge.empty) {
            console.log(
                "Skipping duplicate nudge:",
                account.id,
                deliveryWindow,
                dateKey,
            );
            continue;
          }

          await db
              .collection("families")
              .doc(familyId)
              .collection("nudges")
              .add({
                prompt: finalPrompt,
                promptText: finalPrompt,
                promptId: selectedPrompt.id,
                promptCategory: finalPromptCategory,
                promptVariant: selectedPrompt.variant,
                promptSource: selectedPrompt.source,
                promptGenerationMode: promptGenerationMode,
                targetAccountId: account.id,
                targetRole: role,
                nudgeType: nudgeType,
                deliveryWindow: deliveryWindow,
                dateKey: dateKey,
                status: "pending",

                notificationStatus: "not_sent",
                notificationSentAt: null,
                openedAt: null,
                answeredAt: null,
                ignoredAt: null,
                responseLatencySeconds: null,
                openLatencySeconds: null,

                createdAt: admin.firestore.FieldValue.serverTimestamp(),
                scheduledFor: admin.firestore.FieldValue.serverTimestamp(),
              });

          console.log(
              "Created nudge:",
              familyId,
              account.id,
              deliveryWindow,
              dateKey,
          );
        }
      }

      console.log("Window-based nudge check completed");
      return null;
    });

exports.generateTestNudges = functions
    .runWith({secrets: ["OPENAI_API_KEY"]})
    .https.onRequest(async (req, res) => {
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

          const now = new Date();
          const dateKey = now.toISOString().split("T")[0];

          const nudgeType = role === "child" ? "check_in" : "reflection";
          const deliveryWindow =
            role === "child" ? "child_afternoon" : "parent_evening";

          const selectedPrompt = await pickPromptForAccount(
              db,
              familyId,
              account.id,
              deliveryWindow,
          );

          if (!selectedPrompt) {
            console.log("No prompt found for deliveryWindow:", deliveryWindow);
            continue;
          }

          let finalPrompt = selectedPrompt.text;
          let finalPromptCategory = selectedPrompt.category;
          let promptGenerationMode = "library";

          if (role === "parent" && deliveryWindow === "parent_evening") {
            try {
              const childData = await getLatestChildResponse(familyId);

              if (childData && childData.text) {
                const result = await generateParentPromptFromChildText(
                    childData.text,
                );

                if (result && result.parentPrompt) {
                  finalPrompt = result.parentPrompt;
                  promptGenerationMode = "llm_context";

                  if (result.contextType === "positive") {
                    finalPromptCategory = "parent_evening_context_positive";
                  } else if (result.contextType === "challenging") {
                    finalPromptCategory = "parent_evening_context_challenging";
                  } else if (result.contextType === "neutral") {
                    finalPromptCategory = "parent_evening_context_neutral";
                  }
                  console.log(
                      "Using LLM parent test prompt:",
                      finalPrompt,
                      "category:",
                      finalPromptCategory,
                  );
                }
              }
            } catch (err) {
              console.error("LLM fallback to default test prompt:", err);
            }
          }

          const existingNudge = await db
              .collection("families")
              .doc(familyId)
              .collection("nudges")
              .where("targetAccountId", "==", account.id)
              .where("deliveryWindow", "==", deliveryWindow)
              .where("dateKey", "==", dateKey)
              .limit(1)
              .get();

          if (!existingNudge.empty) {
            console.log(
                "Skipping duplicate nudge:",
                account.id,
                deliveryWindow,
                dateKey,
            );
            continue;
          }

          await db
              .collection("families")
              .doc(familyId)
              .collection("nudges")
              .add({
                prompt: finalPrompt,
                promptText: finalPrompt,
                promptId: selectedPrompt.id,
                promptCategory: finalPromptCategory,
                promptVariant: selectedPrompt.variant,
                promptSource: selectedPrompt.source,
                promptGenerationMode: promptGenerationMode,
                targetAccountId: account.id,
                targetRole: role,
                nudgeType: nudgeType,
                deliveryWindow: deliveryWindow,
                dateKey: dateKey,
                status: "pending",

                notificationStatus: "not_sent",
                notificationSentAt: null,
                openedAt: null,
                answeredAt: null,
                ignoredAt: null,
                responseLatencySeconds: null,
                openLatencySeconds: null,

                createdAt: admin.firestore.FieldValue.serverTimestamp(),
                scheduledFor: admin.firestore.FieldValue.serverTimestamp(),
              });
        }
      }

      res.send("Test nudges generated");
    });

exports.sendNudgeNotification = functions.firestore
    .document("families/{familyId}/nudges/{nudgeId}")
    .onCreate(async (snap, context) => {
      const db = admin.firestore();
      const nudge = snap.data();

      const familyId = context.params.familyId;
      const nudgeId = context.params.nudgeId;
      const targetAccountId = nudge.targetAccountId;
      const prompt = nudge.prompt;

      if (!targetAccountId) {
        console.log("No targetAccountId found on nudge");
        return null;
      }

      const deviceSnapshot = await db
          .collection("device_registrations")
          .where("familyId", "==", familyId)
          .where("accountId", "==", targetAccountId)
          .limit(1)
          .get();

      if (deviceSnapshot.empty) {
        console.log("No device found for account:", targetAccountId);
        return null;
      }

      const deviceData = deviceSnapshot.docs[0].data();
      const admToken = deviceData.admToken;

      if (!admToken) {
        console.log("Device has no ADM token");
        return null;
      }

      const accessToken = await getAdmAccessToken();

      await postJson(
          "https://api.amazon.com/messaging/registrations/" +
          `${admToken}/messages`,
          {
            data: {
              title: "New Nudge",
              body: prompt,
            },
            priority: "high",
            expiresAfter: 3600,
          },
          accessToken,
      );
      await db
          .collection("families")
          .doc(familyId)
          .collection("nudges")
          .doc(nudgeId)
          .update({
            notificationStatus: "sent",
            notificationSentAt: admin.firestore.FieldValue.serverTimestamp(),
          });

      console.log("Notification sent for nudge:", context.params.nudgeId);

      return null;
    });
exports.markIgnoredNudges = functions.https.onRequest(async (req, res) => {
  const db = admin.firestore();

  try {
    const cutoffMs = Date.now() - (10 * 60 * 1000);
    const cutoffDate = new Date(cutoffMs);

    const snap = await db
        .collectionGroup("nudges")
        .where("status", "==", "pending")
        .where("notificationStatus", "==", "sent")
        .where("notificationSentAt", "<=", cutoffDate)
        .get();

    if (snap.empty) {
      res.status(200).send("No ignored nudges to mark.");
      return;
    }

    const batch = db.batch();

    snap.docs.forEach((doc) => {
      batch.update(doc.ref, {
        notificationStatus: "ignored",
        ignoredAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    });

    await batch.commit();

    res.status(200).send(`Marked ${snap.size} nudges as ignored.`);
  } catch (error) {
    console.error("markIgnoredNudges failed:", error);
    res.status(500).send("Error marking ignored nudges.");
  }
});
