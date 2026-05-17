/* eslint-disable require-jsdoc */
const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");
const https = require("https");
const querystring = require("querystring");
const OpenAI = require("openai");
const { defineSecret } = require("firebase-functions/params");

const openaiApiKey = defineSecret("OPENAI_API_KEY");

admin.initializeApp();

const APP_TIME_ZONE = "America/Boise";

exports.testOpenAI = functions
  .runWith({ secrets: ["OPENAI_API_KEY"] })
  .https.onRequest(async (req, res) => {
    try {
      const client = new OpenAI({
        apiKey: openaiApiKey.value(),
      });

      const response = await client.chat.completions.create({
        model: "gpt-4o-mini",
        messages: [
          { role: "user", content: "Say hello in 5 words." },
        ],
      });

      const text = response.choices[0].message.content;

      res.send({ success: true, text });
    } catch (err) {
      console.error(err);
      res.status(500).send({ error: err.message });
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

      const startOfDay = getStartOfLocalDayUtc(new Date());

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
  .runWith({ secrets: ["OPENAI_API_KEY"] })
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

async function getLatestChildResponse(familyId) {
  const startOfDay = getStartOfLocalDayUtc(new Date());

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

async function analyzeChildResponseTone(childText) {
  if (!childText || !childText.trim()) {
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
You analyze a CHILD'S written reflection about their digital experience.

Your job:
1. detect the main emotion
2. choose one simple emoji for that emotion
3. decide whether the response sounds concerning enough that a parent
  should be gently encouraged to check in

Important:
- Be careful and conservative
- "Concerning" does NOT mean every negative feeling
- Mild frustration, annoyance, boredom, or losing a game is
  usually NOT concerning
- Mark as concerning only if the child sounds significantly distressed,
  emotionally overwhelmed, unsafe, fearful, hopeless, repeatedly harmed,
  bullied, threatened, or seriously troubled

Return JSON only in this exact format:
{
 "emotionLabel":
 "happy | sad | angry | frustrated | worried | calm | excited | neutral",
 "emotionEmoji": "🙂",
 "toneCategory": "positive | neutral | negative",
 "isConcerning": true,
 "concernReason": "short explanation"
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

  return {
    emotionLabel: parsed.emotionLabel || "neutral",
    emotionEmoji: parsed.emotionEmoji || "😐",
    toneCategory: parsed.toneCategory || "neutral",
    isConcerning: parsed.isConcerning === true,
    concernReason: parsed.concernReason || "",
  };
}

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

function pickRandom(items) {
  if (!items || !items.length) {
    return null;
  }

  const index = Math.floor(Math.random() * items.length);
  return items[index];
}

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

exports.sendFcmTestNotification = functions.https.onRequest(
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
      const fcmToken = deviceData.fcmToken;

      if (!fcmToken) {
        res.status(400).send("This device registration has no fcmToken.");
        return;
      }

      const message = {
        token: fcmToken,
        notification: {
          title: "KTB Backend Test",
          body: "This notification was sent from Firebase Functions.",
        },
        data: {
          click_action: "FLUTTER_NOTIFICATION_CLICK",
        },
        android: {
          priority: "high",
        },
      };

      const response = await admin.messaging().send(message);

      res.status(200).send({
        success: true,
        uid: uid,
        fcmMessageId: response,
      });
    } catch (error) {
      console.error("sendFcmTestNotification error:", error);
      res.status(500).send({
        success: false,
        error: error.message,
      });
    }
  },
);

function getLocalTimeParts(date = new Date()) {
  const formatter = new Intl.DateTimeFormat("en-CA", {
    timeZone: APP_TIME_ZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    hour12: false,
  });

  const parts = formatter.formatToParts(date);
  const map = {};

  for (const part of parts) {
    map[part.type] = part.value;
  }

  return {
    year: map.year,
    month: map.month,
    day: map.day,
    hour: Number(map.hour),
    dateKey: `${map.year}-${map.month}-${map.day}`,
  };
}

function getBoiseOffsetForDateKey(dateKey) {
  const testDate = new Date(`${dateKey}T12:00:00Z`);

  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone: APP_TIME_ZONE,
    timeZoneName: "shortOffset",
  });

  const parts = formatter.formatToParts(testDate);
  const timeZonePart = parts.find((part) => part.type === "timeZoneName");
  const value = timeZonePart ? timeZonePart.value : "GMT-6";
  const match = value.match(/GMT([+-]\d{1,2})(?::(\d{2}))?/);

  if (!match) {
    return "-06:00";
  }

  const hourNumber = Number(match[1]);
  const minuteText = match[2] || "00";
  const sign = hourNumber >= 0 ? "+" : "-";
  const hourText = String(Math.abs(hourNumber)).padStart(2, "0");

  return `${sign}${hourText}:${minuteText}`;
}

function getStartOfLocalDayUtc(date = new Date()) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: APP_TIME_ZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);

  const map = {};
  for (const part of parts) {
    map[part.type] = part.value;
  }

  const dateKey = `${map.year}-${map.month}-${map.day}`;
  const offset = getBoiseOffsetForDateKey(dateKey);

  return new Date(`${dateKey}T00:00:00${offset}`);
}

function getBoiseDateForLocalTime(dateKey, hour, minute, second) {
  const offset = getBoiseOffsetForDateKey(dateKey);
  const hourText = String(hour).padStart(2, "0");
  const minuteText = String(minute).padStart(2, "0");
  const secondText = String(second).padStart(2, "0");

  return new Date(
    `${dateKey}T${hourText}:${minuteText}:${secondText}${offset}`,
  );
}

function getRandomScheduledTime(dateKey, startHour, endHour) {
  const hourRange = endHour - startHour;
  const randomHour = startHour + Math.floor(Math.random() * hourRange);
  const randomMinute = Math.floor(Math.random() * 60);
  const randomSecond = Math.floor(Math.random() * 60);

  return getBoiseDateForLocalTime(
    dateKey,
    randomHour,
    randomMinute,
    randomSecond,
  );
}

function getScheduledTimeForWindow(dateKey, deliveryWindow) {
  if (deliveryWindow === "parent_morning") {
    return getRandomScheduledTime(dateKey, 7, 9);
  } else if (deliveryWindow === "child_afternoon") {
    return getRandomScheduledTime(dateKey, 15, 17);
  } else if (deliveryWindow === "child_night") {
    return getRandomScheduledTime(dateKey, 18, 20);
  } else if (deliveryWindow === "parent_evening") {
    return getRandomScheduledTime(dateKey, 20, 22);
  }

  return null;
}

async function sendNudgeToTarget(db, familyId, nudgeId, nudge) {
  const targetAccountId = nudge.targetAccountId;
  const prompt = nudge.prompt;

  if (!targetAccountId) {
    throw new Error("No targetAccountId found on nudge");
  }

  const deviceSnapshot = await db
    .collection("device_registrations")
    .where("familyId", "==", familyId)
    .where("accountId", "==", targetAccountId)
    .limit(1)
    .get();

  if (deviceSnapshot.empty) {
    throw new Error(`No device found for account: ${targetAccountId}`);
  }

  const deviceData = deviceSnapshot.docs[0].data();
  const tokenType = deviceData.tokenType;
  const fcmToken = deviceData.fcmToken;
  const admToken = deviceData.admToken || deviceData.admRegistrationId;

  if (tokenType === "fcm" && fcmToken) {
    await admin.messaging().send({
      token: fcmToken,
      notification: {
        title: "New Nudge",
        body: prompt,
      },
      data: {
        familyId: familyId,
        nudgeId: nudgeId,
        click_action: "FLUTTER_NOTIFICATION_CLICK",
      },
      android: {
        priority: "high",
      },
      apns: {
        headers: {
          "apns-priority": "10",
        },
        payload: {
          aps: {
            sound: "default",
            badge: 1,
          },
        },
      },
      
    });

    console.log("FCM notification sent for nudge:", nudgeId);
  } else if (tokenType === "adm" && admToken) {
    const accessToken = await getAdmAccessToken();

    await postJson(
      "https://api.amazon.com/messaging/registrations/" +
      `${admToken}/messages`,
      {
        data: {
          title: "New Nudge",
          body: prompt,
          familyId: familyId,
          nudgeId: nudgeId,
        },
        priority: "high",
        expiresAfter: 3600,
      },
      accessToken,
    );

    console.log("ADM notification sent for nudge:", nudgeId);
  } else {
    throw new Error("Device has no supported push token");
  }
}

exports.generateDailyNudges = functions
  .runWith({ secrets: ["OPENAI_API_KEY"] })
  .pubsub.schedule("every day 00:05")
  .timeZone(APP_TIME_ZONE)
  .onRun(async () => {
    const db = admin.firestore();
    const now = new Date();
    const localParts = getLocalTimeParts(now);
    const dateKey = localParts.dateKey;

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

        let windows = [];

        if (role === "parent") {
          windows = [
            {
              deliveryWindow: "parent_morning",
              nudgeType: "check_in",
            },
            {
              deliveryWindow: "parent_evening",
              nudgeType: "reflection",
            },
          ];
        } else if (role === "child") {
          windows = [
            {
              deliveryWindow: "child_afternoon",
              nudgeType: "check_in",
            },
            {
              deliveryWindow: "child_night",
              nudgeType: "reflection",
            },
          ];
        } else {
          continue;
        }

        for (const windowItem of windows) {
          const deliveryWindow = windowItem.deliveryWindow;
          const nudgeType = windowItem.nudgeType;

          const selectedPrompt = await pickPromptForAccount(
            db,
            familyId,
            account.id,
            deliveryWindow,
          );

          if (!selectedPrompt) {
            console.log(
              "No prompt found for deliveryWindow:",
              deliveryWindow,
            );
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
                    finalPromptCategory =
                      "parent_evening_context_challenging";
                  } else {
                    finalPromptCategory = "parent_evening_context_neutral";
                  }
                }
              }
            } catch (err) {
              console.error("LLM fallback to default prompt:", err);
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

          const scheduledForTime = getScheduledTimeForWindow(
            dateKey,
            deliveryWindow,
          );

          if (!scheduledForTime) {
            console.log(
              "Could not determine scheduled time for:",
              deliveryWindow,
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
              scheduledFor:
                admin.firestore.Timestamp.fromDate(scheduledForTime),
            });

          console.log(
            "Created nudge:",
            familyId,
            account.id,
            deliveryWindow,
            dateKey,
            "scheduledFor:",
            scheduledForTime.toISOString(),
          );
        }
      }
    }

    console.log("Daily nudges created for all windows");
    return null;
  });

exports.generateTestNudges = functions
  .runWith({ secrets: ["OPENAI_API_KEY"] })
  .https.onRequest(async (req, res) => {
    const db = admin.firestore();
    const mode = req.query.mode || "instant";

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
        const localParts = getLocalTimeParts(now);
        const dateKey = localParts.dateKey;

        let windows = [];

        if (role === "parent") {
          windows = [
            {
              deliveryWindow: "parent_morning",
              nudgeType: "check_in",
            },
            {
              deliveryWindow: "parent_evening",
              nudgeType: "reflection",
            },
          ];
        } else if (role === "child") {
          windows = [
            {
              deliveryWindow: "child_afternoon",
              nudgeType: "check_in",
            },
            {
              deliveryWindow: "child_night",
              nudgeType: "reflection",
            },
          ];
        } else {
          continue;
        }

        for (const windowItem of windows) {
          const deliveryWindow = windowItem.deliveryWindow;
          const nudgeType = windowItem.nudgeType;

          const selectedPrompt = await pickPromptForAccount(
            db,
            familyId,
            account.id,
            deliveryWindow,
          );

          if (!selectedPrompt) {
            console.log(
              "No prompt found for deliveryWindow:",
              deliveryWindow,
            );
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
                    finalPromptCategory =
                      "parent_evening_context_challenging";
                  } else {
                    finalPromptCategory = "parent_evening_context_neutral";
                  }
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

          let scheduledForTime = now;

          if (mode === "scheduled") {
            scheduledForTime = getScheduledTimeForWindow(
              dateKey,
              deliveryWindow,
            );

            if (!scheduledForTime) {
              console.log(
                "Could not determine scheduled time for:",
                deliveryWindow,
              );
              continue;
            }
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
              scheduledFor:
                admin.firestore.Timestamp.fromDate(scheduledForTime),
            });
        }
      }
    }

    res.send(`Test nudges generated in ${mode} mode`);
  });

exports.sendNudgeNotification = functions.firestore
  .document("families/{familyId}/nudges/{nudgeId}")
  .onCreate(async (snap, context) => {
    const nudge = snap.data();
    const scheduledFor = nudge.scheduledFor ?
      nudge.scheduledFor.toDate() :
      null;

    console.log(
      "Nudge created, waiting for scheduled sender:",
      context.params.nudgeId,
      scheduledFor ? scheduledFor.toISOString() : "no scheduled time",
    );

    return null;
  });

exports.sendScheduledNotifications = functions.pubsub
  .schedule("every 1 minutes")
  .timeZone(APP_TIME_ZONE)
  .onRun(async () => {
    const db = admin.firestore();
    const now = new Date();

    const snap = await db
      .collectionGroup("nudges")
      .where("notificationStatus", "==", "not_sent")
      .where(
        "scheduledFor",
        "<=",
        admin.firestore.Timestamp.fromDate(now),
      )
      .get();

    if (snap.empty) {
      console.log("No scheduled nudges ready to send.");
      return null;
    }

    for (const doc of snap.docs) {
      const nudge = doc.data();
      const familyRef = doc.ref.parent.parent;

      if (!familyRef) {
        console.log("Could not resolve family for nudge:", doc.id);
        continue;
      }

      const familyId = familyRef.id;
      const nudgeId = doc.id;

      try {
        await sendNudgeToTarget(db, familyId, nudgeId, nudge);

        await doc.ref.update({
          notificationStatus: "sent",
          notificationSentAt:
            admin.firestore.FieldValue.serverTimestamp(),
        });
      } catch (error) {
        console.error(
          "sendScheduledNotifications failed for nudge:",
          nudgeId,
          error,
        );

        await doc.ref.update({
          notificationStatus: "failed",
          notificationError: error.message,
        });
      }
    }

    return null;
  });

exports.analyzeAnsweredChildNudge = functions
  .runWith({ secrets: ["OPENAI_API_KEY"] })
  .firestore
  .document("families/{familyId}/nudges/{nudgeId}")
  .onUpdate(async (change, context) => {
    const before = change.before.data();
    const after = change.after.data();

    if (!before || !after) {
      return null;
    }

    const beforeStatus = before.status;
    const afterStatus = after.status;

    if (beforeStatus === "answered") {
      return null;
    }

    if (afterStatus !== "answered") {
      return null;
    }

    if (after.targetRole !== "child") {
      return null;
    }

    const responseText = after.response &&
      after.response.text ? after.response.text.trim() : "";

    if (!responseText) {
      return null;
    }

    try {
      const analysis = await analyzeChildResponseTone(responseText);

      if (!analysis) {
        return null;
      }

      await change.after.ref.update({
        emotionLabel: analysis.emotionLabel,
        emotionEmoji: analysis.emotionEmoji,
        toneCategory: analysis.toneCategory,
        isConcerning: analysis.isConcerning,
        concernReason: analysis.concernReason,
        emotionAnalyzedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      console.log(
        "Child answer analyzed:",
        context.params.nudgeId,
        analysis,
      );
    } catch (error) {
      console.error(
        "analyzeAnsweredChildNudge failed:",
        context.params.nudgeId,
        error,
      );

      await change.after.ref.update({
        emotionAnalysisError: error.message,
      });
    }

    return null;
  });

exports.sendParentConcernAlert = functions.firestore
  .document("families/{familyId}/nudges/{nudgeId}")
  .onUpdate(async (change, context) => {
    const before = change.before.data();
    const after = change.after.data();

    if (!before || !after) {
      return null;
    }

    if (after.targetRole !== "child") {
      return null;
    }

    if (before.isConcerning === true) {
      return null;
    }

    if (after.isConcerning !== true) {
      return null;
    }

    if (after.concernNotificationSentAt) {
      return null;
    }

    const db = admin.firestore();
    const familyId = context.params.familyId;

    try {
      const parentAccountsSnap = await db
        .collection("families")
        .doc(familyId)
        .collection("accounts")
        .where("role", "==", "parent")
        .get();

      if (parentAccountsSnap.empty) {
        console.log("No parent accounts found for family:", familyId);
        return null;
      }

      let sentCount = 0;

      for (const parentDoc of parentAccountsSnap.docs) {
        const parentAccountId = parentDoc.id;

        const deviceSnapshot = await db
          .collection("device_registrations")
          .where("familyId", "==", familyId)
          .where("accountId", "==", parentAccountId)
          .limit(1)
          .get();

        if (deviceSnapshot.empty) {
          console.log("No device found for parent:", parentAccountId);
          continue;
        }

        const deviceData = deviceSnapshot.docs[0].data();
        const tokenType = deviceData.tokenType;
        const fcmToken = deviceData.fcmToken;
        const admToken = deviceData.admToken ||
          deviceData.admRegistrationId;

        if (tokenType === "fcm" && fcmToken) {
          await admin.messaging().send({
            token: fcmToken,
            notification: {
              title: "Child Check-In Alert",
              body: "Your child may need a gentle check-in.",
            },
            data: {
              familyId: familyId,
              sourceNudgeId: context.params.nudgeId,
              type: "concern_alert",
              click_action: "FLUTTER_NOTIFICATION_CLICK",
            },
            android: {
              priority: "high",
            },
          });

          sentCount++;
        } else if (tokenType === "adm" && admToken) {
          const accessToken = await getAdmAccessToken();

          await postJson(
            "https://api.amazon.com/messaging/registrations/" +
            `${admToken}/messages`,
            {
              data: {
                title: "Child Check-In Alert",
                body: "Your child may need a gentle check-in.",
                type: "concern_alert",
                familyId: familyId,
                sourceNudgeId: context.params.nudgeId,
              },
              priority: "high",
              expiresAfter: 3600,
            },
            accessToken,
          );

          sentCount++;
        } else {
          console.log(
            "Parent device has no supported push token:",
            parentAccountId,
          );
        }
      }

      await change.after.ref.update({
        concernNotificationSentAt:
          admin.firestore.FieldValue.serverTimestamp(),
        concernNotificationStatus: sentCount > 0 ? "sent" : "no_device",
      });

      console.log(
        "Concern alert processed for nudge:",
        context.params.nudgeId,
        "sentCount:",
        sentCount,
      );
    } catch (error) {
      console.error("sendParentConcernAlert failed:", error);

      await change.after.ref.update({
        concernNotificationStatus: "failed",
        concernNotificationError: error.message,
      });
    }

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

exports.createStudyFamily = functions.https.onRequest(async (req, res) => {
  try {
    const db = admin.firestore();

    const parentName = req.query.parentName;
    const childName = req.query.childName;
    const parentPin = req.query.parentPin;
    const childPin = req.query.childPin;

    if (!parentName || !childName || !parentPin || !childPin) {
      return res.status(400).json({
        success: false,
        error: "Missing parentName, childName, parentPin, or childPin.",
      });
    }

    const familyCode = await generateUniqueFamilyCode(db);

    const familyRef = db.collection("families").doc();
    const parentRef = familyRef.collection("accounts").doc("p1");
    const childRef = familyRef.collection("accounts").doc("c1");

    await familyRef.set({
      familyCode: familyCode,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      studyStatus: "active",
    });

    await parentRef.set({
      displayName: parentName,
      role: "parent",
      pin: String(parentPin),
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    await childRef.set({
      displayName: childName,
      role: "child",
      pin: String(childPin),
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return res.status(200).json({
      success: true,
      familyId: familyRef.id,
      familyCode: familyCode,
      parentAccountId: "p1",
      childAccountId: "c1",
      parentPin: String(parentPin),
      childPin: String(childPin),
    });
  } catch (error) {
    console.error("createStudyFamily failed:", error);
    return res.status(500).json({
      success: false,
      error: error.message,
    });
  }
});

function generateFamilyCode() {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  let code = "";

  for (let i = 0; i < 6; i++) {
    const index = Math.floor(Math.random() * chars.length);
    code += chars[index];
  }

  return code;
}

async function generateUniqueFamilyCode(db) {
  for (let attempt = 0; attempt < 10; attempt++) {
    const code = generateFamilyCode();

    const snap = await db
      .collection("families")
      .where("familyCode", "==", code)
      .limit(1)
      .get();

    if (snap.empty) {
      return code;
    }
  }

  throw new Error("Could not generate a unique family code.");
}
