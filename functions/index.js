console.log("index.js start loading");
/*
eslint-disable require-jsdoc */
const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");
const https = require("https");
const querystring = require("querystring");
const OpenAI = require("openai");
const {defineSecret} = require("firebase-functions/params");

const openaiApiKey = defineSecret("OPENAI_API_KEY");

admin.initializeApp();

const APP_TIME_ZONE = "America/Boise";

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

// Question bank, organized by delivery window then by specific
// sub-category (not just one generic bucket per window). parent_morning
// deliberately avoids any "so far today" / "today" framing about the
// child's tech use — this nudge fires at 7-9am, before the child has
// necessarily touched a device, so those questions used to be
// unanswerable. It's reframed as forward-looking (intentions, planning,
// general wellbeing) instead of retrospective.
function getPromptBank() {
  return {
    parent_morning: [
      // todays_intentions
      {
        id: "parent_morning_intent_1",
        category: "todays_intentions",
        variant: "hope_for_today",
        source: "library",
        text:
          "What's one thing you hope your child spends time on today, " +
          "screen or otherwise?",
      },
      {
        id: "parent_morning_intent_2",
        category: "todays_intentions",
        variant: "watch_list",
        source: "library",
        text: "Is there a specific app or game you want to keep an eye on today?",
      },
      {
        id: "parent_morning_intent_3",
        category: "todays_intentions",
        variant: "good_day_definition",
        source: "library",
        text:
          "What would a 'good day' with technology look like for your " +
          "child today?",
      },
      // general_wellbeing
      {
        id: "parent_morning_wellbeing_1",
        category: "general_wellbeing",
        variant: "sleep_and_mood",
        source: "library",
        text:
          "How did your child sleep last night — do you expect that to " +
          "affect their mood today?",
      },
      {
        id: "parent_morning_wellbeing_2",
        category: "general_wellbeing",
        variant: "emotional_state",
        source: "library",
        text: "Does your child seem excited, anxious, or neutral about today?",
      },
      {
        id: "parent_morning_wellbeing_3",
        category: "general_wellbeing",
        variant: "whats_on_their_mind",
        source: "library",
        text:
          "Is there anything on your child's mind today that might affect " +
          "how they use their devices?",
      },
      // family_planning
      {
        id: "parent_morning_planning_1",
        category: "family_planning",
        variant: "screen_free_plans",
        source: "library",
        text: "Do you have any screen-free activities planned with your child today?",
      },
      {
        id: "parent_morning_planning_2",
        category: "family_planning",
        variant: "day_type",
        source: "library",
        text:
          "Is today a school day, weekend, or holiday — does that change " +
          "what you expect from their screen time?",
      },
      {
        id: "parent_morning_planning_3",
        category: "family_planning",
        variant: "device_free_moment",
        source: "library",
        text:
          "Is there a family activity today where you'd like devices to " +
          "stay put away?",
      },
      // parenting_reflection
      {
        id: "parent_morning_reflection_1",
        category: "parenting_reflection",
        variant: "boundary_reinforcement",
        source: "library",
        text: "What's one boundary around technology you want to reinforce today?",
      },
      {
        id: "parent_morning_reflection_2",
        category: "parenting_reflection",
        variant: "follow_up_conversation",
        source: "library",
        text:
          "Is there a recent conversation about screens you want to " +
          "follow up on today?",
      },
      {
        id: "parent_morning_reflection_3",
        category: "parenting_reflection",
        variant: "modeling_behavior",
        source: "library",
        text:
          "What's one thing you're hoping to model for your child today, " +
          "tech-related or not?",
      },
    ],

    child_afternoon: [
      // mood_and_screens
      {
        id: "child_afternoon_mood_1",
        category: "mood_and_screens",
        variant: "feelings_check",
        source: "library",
        text: "How are you feeling about your screen time so far today?",
      },
      {
        id: "child_afternoon_mood_2",
        category: "mood_and_screens",
        variant: "good_moment",
        source: "library",
        text: "Has anything online made you laugh, smile, or feel good today?",
      },
      {
        id: "child_afternoon_mood_3",
        category: "mood_and_screens",
        variant: "chill_vs_chaotic",
        source: "library",
        text:
          "On a scale of chill to chaotic, how has your screen time felt " +
          "today?",
      },
      // specific_activity
      {
        id: "child_afternoon_activity_1",
        category: "specific_activity",
        variant: "most_time_spent",
        source: "library",
        text: "What app or game have you spent the most time on today?",
      },
      {
        id: "child_afternoon_activity_2",
        category: "specific_activity",
        variant: "made_or_learned",
        source: "library",
        text: "Did you make or learn anything using a screen today?",
      },
      {
        id: "child_afternoon_activity_3",
        category: "specific_activity",
        variant: "most_interesting",
        source: "library",
        text: "What's the most interesting thing you've done on a screen today?",
      },
      // social_online
      {
        id: "child_afternoon_social_1",
        category: "social_online",
        variant: "friends_online",
        source: "library",
        text: "Did you talk to any friends online today? How did that feel?",
      },
      {
        id: "child_afternoon_social_2",
        category: "social_online",
        variant: "stuck_with_you",
        source: "library",
        text: "Has anything you saw online today stuck with you?",
      },
      {
        id: "child_afternoon_social_3",
        category: "social_online",
        variant: "proud_share",
        source: "library",
        text: "Did you share anything online today you were proud of?",
      },
      // frustration_check
      {
        id: "child_afternoon_frustration_1",
        category: "frustration_check",
        variant: "annoyance_check",
        source: "library",
        text:
          "Was there anything about using a screen today that felt " +
          "frustrating or annoying?",
      },
      {
        id: "child_afternoon_frustration_2",
        category: "frustration_check",
        variant: "made_it_worse",
        source: "library",
        text: "Did any app or website make you feel worse instead of better today?",
      },
      {
        id: "child_afternoon_frustration_3",
        category: "frustration_check",
        variant: "wish_different",
        source: "library",
        text: "Is there anything about your screen time today you wish had gone differently?",
      },
    ],

    parent_evening: [
      // daily_observation
      {
        id: "parent_evening_observation_1",
        category: "daily_observation",
        variant: "relationship_with_screens",
        source: "library",
        text:
          "Looking back at today, how would you describe your child's " +
          "relationship with screens?",
      },
      {
        id: "parent_evening_observation_2",
        category: "daily_observation",
        variant: "needs_a_break",
        source: "library",
        text:
          "Did you see any signs today that your child might need a tech " +
          "break tomorrow?",
      },
      {
        id: "parent_evening_observation_3",
        category: "daily_observation",
        variant: "surprised_you",
        source: "library",
        text:
          "What's one thing you noticed about your child's tech use today " +
          "that surprised you?",
      },
      // connection_moments
      {
        id: "parent_evening_connection_1",
        category: "connection_moments",
        variant: "tech_helped_connect",
        source: "library",
        text:
          "Was there a moment today when technology helped you connect " +
          "with your child, rather than distract?",
      },
      {
        id: "parent_evening_connection_2",
        category: "connection_moments",
        variant: "screens_got_in_way",
        source: "library",
        text: "Did screens get in the way of a conversation or activity today?",
      },
      {
        id: "parent_evening_connection_3",
        category: "connection_moments",
        variant: "screen_free_together",
        source: "library",
        text: "Did you and your child do anything screen-free together today?",
      },
      // balance_check
      {
        id: "parent_evening_balance_1",
        category: "balance_check",
        variant: "more_or_less_than_expected",
        source: "library",
        text: "Compared to a typical day, was today more or less screen time than expected?",
      },
      {
        id: "parent_evening_balance_2",
        category: "balance_check",
        variant: "other_activities",
        source: "library",
        text:
          "Did your child balance screen time with other activities " +
          "today (outdoors, reading, chores)?",
      },
      {
        id: "parent_evening_balance_3",
        category: "balance_check",
        variant: "self_regulation",
        source: "library",
        text:
          "Did your child seem to self-regulate their screen time today, " +
          "or need reminders?",
      },
      // tomorrow_prep
      {
        id: "parent_evening_prep_1",
        category: "tomorrow_prep",
        variant: "try_differently",
        source: "library",
        text: "Is there anything you want to try differently with screen time tomorrow?",
      },
      {
        id: "parent_evening_prep_2",
        category: "tomorrow_prep",
        variant: "boundary_or_reward",
        source: "library",
        text: "Do you want to set a new boundary or reward based on today?",
      },
      {
        id: "parent_evening_prep_3",
        category: "tomorrow_prep",
        variant: "praise_or_address",
        source: "library",
        text:
          "Is there something you want to praise or address with your " +
          "child about today's screen use?",
      },
    ],

    child_night: [
      // gratitude_and_highlights
      {
        id: "child_night_gratitude_1",
        category: "gratitude_and_highlights",
        variant: "good_screen_moment",
        source: "library",
        text: "What's one good thing that happened on your screen today?",
      },
      {
        id: "child_night_gratitude_2",
        category: "gratitude_and_highlights",
        variant: "grateful_for",
        source: "library",
        text: "What are you grateful for from today, screen-related or not?",
      },
      {
        id: "child_night_gratitude_3",
        category: "gratitude_and_highlights",
        variant: "best_part_of_day",
        source: "library",
        text: "What was the best part of your day today?",
      },
      // self_awareness
      {
        id: "child_night_awareness_1",
        category: "self_awareness",
        variant: "spent_time_as_wanted",
        source: "library",
        text: "Do you think you spent your screen time today the way you wanted to?",
      },
      {
        id: "child_night_awareness_2",
        category: "self_awareness",
        variant: "do_differently",
        source: "library",
        text: "Is there anything you'd do differently with your screen time tomorrow?",
      },
      {
        id: "child_night_awareness_3",
        category: "self_awareness",
        variant: "before_and_after_feeling",
        source: "library",
        text: "Did you notice how you felt before and after using screens today?",
      },
      // tomorrow_goals
      {
        id: "child_night_goals_1",
        category: "tomorrow_goals",
        variant: "want_to_do_tomorrow",
        source: "library",
        text: "Is there something fun or productive you want to do on a screen tomorrow?",
      },
      {
        id: "child_night_goals_2",
        category: "tomorrow_goals",
        variant: "want_to_do_less",
        source: "library",
        text: "Is there an app or game you want to spend less time on tomorrow?",
      },
      {
        id: "child_night_goals_3",
        category: "tomorrow_goals",
        variant: "non_screen_goal",
        source: "library",
        text: "What's one thing you want to do tomorrow that isn't on a screen?",
      },
      // sleep_and_screens
      {
        id: "child_night_sleep_1",
        category: "sleep_and_screens",
        variant: "ready_for_bed",
        source: "library",
        text: "Do you feel ready to put your screen away and get good sleep tonight?",
      },
      {
        id: "child_night_sleep_2",
        category: "sleep_and_screens",
        variant: "relax_or_wind_up",
        source: "library",
        text: "Did screens help you relax tonight, or make it harder to wind down?",
      },
      {
        id: "child_night_sleep_3",
        category: "sleep_and_screens",
        variant: "time_before_bed",
        source: "library",
        text: "How much time before bed did you put your screen away tonight?",
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

// Excludes prompt ids used in the last RECENT_PROMPT_HISTORY nudges for this
// account+window (not just the single most recent one) — with only 3-4
// prompts per window before, excluding just the last pick meant the same
// question could reappear the very next time it was sent; a 5-nudge lookback
// keeps things feeling varied even before the bigger bank existed.
const RECENT_PROMPT_HISTORY = 5;

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

  const recentSnapshot = await db
      .collection("families")
      .doc(familyId)
      .collection("nudges")
      .where("targetAccountId", "==", accountId)
      .where("deliveryWindow", "==", deliveryWindow)
      .orderBy("createdAt", "desc")
      .limit(RECENT_PROMPT_HISTORY)
      .get();

  const recentPromptIds = new Set(
      recentSnapshot.docs
          .map((doc) => doc.data().promptId)
          .filter((id) => !!id),
  );

  let eligiblePrompts = prompts;

  if (recentPromptIds.size > 0) {
    const filtered = prompts.filter(
        (prompt) => !recentPromptIds.has(prompt.id),
    );

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

// Defaults match the original hardcoded ranges — used when a family hasn't
// customized their child's nudge delivery windows yet.
const DEFAULT_CHILD_WINDOWS = {
  child_afternoon: {startHour: 15, endHour: 17},
  child_night: {startHour: 18, endHour: 20},
};

// Reads the parent-configured delivery windows for the child's two daily
// nudges from families/{familyId}/settings/nudges (set via the "Nudge
// delivery window for the child" UI in the Nudges tab). Falls back to
// DEFAULT_CHILD_WINDOWS for any window not yet customized. Only the child's
// windows are configurable this way — parent_morning/parent_evening stay
// fixed, since this feature is specifically about the child's delivery times.
async function getChildNudgeWindows(db, familyId) {
  try {
    const doc = await db
        .collection("families")
        .doc(familyId)
        .collection("settings")
        .doc("nudges")
        .get();

    if (!doc.exists) {
      return DEFAULT_CHILD_WINDOWS;
    }

    const data = doc.data() || {};
    return {
      child_afternoon: data.childWindow1 || DEFAULT_CHILD_WINDOWS.child_afternoon,
      child_night: data.childWindow2 || DEFAULT_CHILD_WINDOWS.child_night,
    };
  } catch (err) {
    console.error("Failed to read nudge window settings, using defaults:", err);
    return DEFAULT_CHILD_WINDOWS;
  }
}

function getScheduledTimeForWindow(dateKey, deliveryWindow, childWindows) {
  if (deliveryWindow === "parent_morning") {
    return getRandomScheduledTime(dateKey, 7, 9);
  } else if (deliveryWindow === "parent_evening") {
    return getRandomScheduledTime(dateKey, 20, 22);
  } else if (deliveryWindow === "child_afternoon" || deliveryWindow === "child_night") {
    const windows = childWindows || DEFAULT_CHILD_WINDOWS;
    const range = windows[deliveryWindow] || DEFAULT_CHILD_WINDOWS[deliveryWindow];
    return getRandomScheduledTime(dateKey, range.startHour, range.endHour);
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
        payload: {
          aps: {
            sound: "default",
          },
        },
        headers: {
          "apns-priority": "10",
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
    .runWith({secrets: ["OPENAI_API_KEY"]})
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
        const childWindows = await getChildNudgeWindows(db, familyId);

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
                childWindows,
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
    .runWith({secrets: ["OPENAI_API_KEY"]})
    .https.onRequest(async (req, res) => {
      const db = admin.firestore();
      const mode = req.query.mode || "instant";

      const familiesSnapshot = await db.collection("families").get();

      for (const familyDoc of familiesSnapshot.docs) {
        const familyId = familyDoc.id;
        const childWindows = await getChildNudgeWindows(db, familyId);

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
                  childWindows,
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
    .schedule("every 5 minutes")
    .timeZone(APP_TIME_ZONE)
    .onRun(async () => {
      const db = admin.firestore();
      const now = admin.firestore.Timestamp.now();

      console.log(
          "sendScheduledNotifications running at:",
          now.toDate().toISOString(),
      );

      const snap = await db
          .collectionGroup("nudges")
          .where("status", "==", "pending")
          .where("notificationSentAt", "==", null)
          .where("scheduledFor", "<=", now)
          .get();

      console.log("Scheduled nudges found:", snap.size);

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

        console.log(
            "Trying to send nudge:",
            nudgeId,
            "family:",
            familyId,
            "targetAccount:",
            nudge.targetAccountId,
            "scheduledFor:",
            nudge.scheduledFor ?
            nudge.scheduledFor.toDate().toISOString() : null,
        );

        try {
          await sendNudgeToTarget(db, familyId, nudgeId, nudge);

          await doc.ref.update({
            notificationStatus: "sent",
            notificationSentAt:
              admin.firestore.FieldValue.serverTimestamp(),
            notificationError: admin.firestore.FieldValue.delete(),
          });

          // Write to notification inbox so recipients see it in-app
          if (nudge.targetRole) {
            await writeNotificationDoc(db, familyId, {
              title: "New Nudge",
              body: nudge.prompt || "You have a new nudge",
              type: "nudge",
              targetRole: nudge.targetRole,
            });
          }

          console.log("Nudge notification sent successfully:", nudgeId);
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
    .runWith({secrets: ["OPENAI_API_KEY"]})
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

// Notify parent immediately when their child answers any nudge
exports.notifyParentOnChildAnswer = functions.firestore
    .document("families/{familyId}/nudges/{nudgeId}")
    .onUpdate(async (change, context) => {
      const before = change.before.data();
      const after = change.after.data();

      if (!before || !after) return null;
      if (after.targetRole !== "child") return null;
      if (before.status === "answered") return null; // already answered
      if (after.status !== "answered") return null;  // not yet answered
      if (after.parentAnswerNotificationSentAt) return null; // already notified

      const db = admin.firestore();
      const familyId = context.params.familyId;

      try {
        const parentSnap = await db
            .collection("families")
            .doc(familyId)
            .collection("accounts")
            .where("role", "==", "parent")
            .get();

        if (parentSnap.empty) return null;

        let sentCount = 0;

        for (const parentDoc of parentSnap.docs) {
          const parentAccountId = parentDoc.id;

          const deviceSnap = await db
              .collection("device_registrations")
              .where("familyId", "==", familyId)
              .where("accountId", "==", parentAccountId)
              .limit(1)
              .get();

          if (deviceSnap.empty) continue;

          const deviceData = deviceSnap.docs[0].data();
          const tokenType = deviceData.tokenType;
          const fcmToken = deviceData.fcmToken;
          const admToken = deviceData.admToken || deviceData.admRegistrationId;

          if (tokenType === "fcm" && fcmToken) {
            await admin.messaging().send({
              token: fcmToken,
              notification: {
                title: "Your child answered a nudge",
                body: "Check their reflection in the app.",
              },
              data: {
                familyId: familyId,
                nudgeId: context.params.nudgeId,
                type: "child_answered",
                click_action: "FLUTTER_NOTIFICATION_CLICK",
              },
              android: {priority: "high"},
              apns: {
                payload: {aps: {sound: "default"}},
                headers: {"apns-priority": "10"},
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
                    title: "Your child answered a nudge",
                    body: "Check their reflection in the app.",
                    type: "child_answered",
                    familyId: familyId,
                    nudgeId: context.params.nudgeId,
                  },
                  priority: "high",
                  expiresAfter: 3600,
                },
                accessToken,
            );
            sentCount++;
          }
        }

        await change.after.ref.update({
          parentAnswerNotificationSentAt:
            admin.firestore.FieldValue.serverTimestamp(),
          parentAnswerNotificationStatus:
            sentCount > 0 ? "sent" : "no_device",
        });

        if (sentCount > 0) {
          await writeNotificationDoc(db, familyId, {
            title: "Your child answered a nudge",
            body: after.response && after.response.text ?
              after.response.text.substring(0, 80) : "Check their response",
            type: "nudge_answered",
            targetRole: "parent",
          });
        }

        console.log(
            "Parent answer notification for nudge:",
            context.params.nudgeId,
            "sent to",
            sentCount,
            "parent(s)",
        );
      } catch (error) {
        console.error("notifyParentOnChildAnswer failed:", error);
        await change.after.ref.update({
          parentAnswerNotificationStatus: "failed",
          parentAnswerNotificationError: error.message,
        });
      }

      return null;
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
// ── Helper: write a notification record to the family's inbox ─────────────────

async function writeNotificationDoc(db, familyId, {title, body, type, targetRole}) {
  try {
    await db.collection("families").doc(familyId)
        .collection("notifications")
        .add({
          title,
          body,
          type,
          targetRole,
          sentAt: admin.firestore.FieldValue.serverTimestamp(),
        });
  } catch (err) {
    console.error("writeNotificationDoc failed:", err.message);
  }
}

// ── Helper: send push to a single account (fcm or adm) ────────────────────────

async function sendPushToAccount(db, familyId, accountId, title, body, extraData) {
  const deviceSnap = await db
      .collection("device_registrations")
      .where("familyId", "==", familyId)
      .where("accountId", "==", accountId)
      .limit(1)
      .get();

  if (deviceSnap.empty) {
    console.log(`No device for account ${accountId} in family ${familyId}`);
    return false;
  }

  const d = deviceSnap.docs[0].data();
  const tokenType = d.tokenType;
  const fcmToken = d.fcmToken;
  const admToken = d.admToken || d.admRegistrationId;
  const data = Object.assign({click_action: "FLUTTER_NOTIFICATION_CLICK"}, extraData);

  if (tokenType === "fcm" && fcmToken) {
    await admin.messaging().send({
      token: fcmToken,
      notification: {title, body},
      data,
      android: {priority: "high"},
      apns: {
        payload: {aps: {sound: "default"}},
        headers: {"apns-priority": "10"},
      },
    });
    return true;
  } else if (tokenType === "adm" && admToken) {
    const accessToken = await getAdmAccessToken();
    await postJson(
        `https://api.amazon.com/messaging/registrations/${admToken}/messages`,
        {
          data: Object.assign({title, body}, extraData),
          priority: "high",
          expiresAfter: 3600,
        },
        accessToken,
    );
    return true;
  }
  console.log(`No supported push token for account ${accountId}`);
  return false;
}

// ── Helper: send push to all accounts with a given role in a family ───────────

async function sendPushToFamilyRole(db, familyId, role, title, body, extraData) {
  const snap = await db
      .collection("families").doc(familyId)
      .collection("accounts")
      .where("role", "==", role)
      .get();

  let sentCount = 0;
  for (const doc of snap.docs) {
    try {
      const sent = await sendPushToAccount(
          db, familyId, doc.id, title, body, extraData,
      );
      if (sent) sentCount++;
    } catch (err) {
      console.error(`Push failed for account ${doc.id}:`, err.message);
    }
  }
  return sentCount;
}

// ── Trigger: todo list updated → push the other role ──────────────────────────

exports.notifyOnTodoUpdate = functions.firestore
    .document("families/{familyId}/dailyData/{dateKey}")
    .onWrite(async (change, context) => {
      const after = change.after.exists ? change.after.data() : null;
      const before = change.before.exists ? change.before.data() : null;

      if (!after || !after.todosUpdatedAt) return null;

      // Deduplicate: skip if todosUpdatedAt didn't actually advance
      const beforeMs = before && before.todosUpdatedAt ?
        before.todosUpdatedAt.toMillis() : 0;
      if (after.todosUpdatedAt.toMillis() <= beforeMs) return null;

      const updatedByRole = after.updatedByRole;
      if (!updatedByRole) return null;

      const familyId = context.params.familyId;
      const db = admin.firestore();
      const notifyRole = updatedByRole === "parent" ? "child" : "parent";
      const who = updatedByRole === "parent" ? "Parent" : "Child";

      const beforeTodos = Array.isArray(before && before.todos) ?
        before.todos : [];
      const afterTodos = Array.isArray(after.todos) ? after.todos : [];

      // Detect which tasks were newly completed (done flipped to true)
      const beforeDoneSet = new Set(
          beforeTodos.filter((t) => t.done).map((t) => t.text),
      );
      const newlyCompleted = afterTodos.filter(
          (t) => t.done && !beforeDoneSet.has(t.text),
      );

      // Detect which tasks were newly added
      const beforeTextSet = new Set(beforeTodos.map((t) => t.text));
      const newlyAdded = afterTodos.filter(
          (t) => !beforeTextSet.has(t.text) && !t.done,
      );

      const toSend = [];

      for (const task of newlyCompleted) {
        toSend.push({
          title: `${who} completed a task`,
          body: `"${task.text}" has been marked done`,
          type: "todo_complete",
        });
      }
      for (const task of newlyAdded) {
        toSend.push({
          title: `${who} added a new task`,
          body: `New task: "${task.text}"`,
          type: "todo_add",
        });
      }

      // Fallback: generic message if nothing specific was detected
      if (toSend.length === 0) {
        const n = afterTodos.length;
        toSend.push({
          title: `${who} updated the to-do list`,
          body: `To-do list now has ${n === 1 ? "1 task" : `${n} tasks`}`,
          type: "todo_update",
        });
      }

      try {
        for (const notif of toSend) {
          const sentCount = await sendPushToFamilyRole(
              db, familyId, notifyRole, notif.title, notif.body,
              {type: notif.type, familyId},
          );
          await writeNotificationDoc(db, familyId, {
            ...notif, targetRole: notifyRole,
          });
          console.log(
              `notifyOnTodoUpdate (${notif.type}): sent ${sentCount}` +
              ` to ${notifyRole}(s), family: ${familyId}`,
          );
        }
      } catch (err) {
        console.error("notifyOnTodoUpdate failed:", err);
      }

      return null;
    });

// ── Trigger: screen time limit changed → push child or parent ─────────────────

exports.notifyOnScreenTimeLimitChange = functions.firestore
    .document("families/{familyId}/settings/screenTime")
    .onWrite(async (change, context) => {
      const after = change.after.exists ? change.after.data() : null;
      const before = change.before.exists ? change.before.data() : null;

      if (!after) return null;

      const beforeLimit = before ? before.screenTimeLimitMinutes : null;
      const afterLimit = after.screenTimeLimitMinutes;
      if (beforeLimit === afterLimit) return null;

      const updatedByRole = after.updatedByRole;
      if (!updatedByRole) return null;

      const familyId = context.params.familyId;
      const db = admin.firestore();

      try {
        if (updatedByRole === "parent") {
          const title = "Screen time limit updated";
          const body = `Your parent set today's limit to ${afterLimit} minutes`;
          const sentCount = await sendPushToFamilyRole(
              db, familyId, "child", title, body,
              {type: "screen_time_limit", familyId, limitMinutes: String(afterLimit)},
          );
          await writeNotificationDoc(db, familyId, {
            title, body, type: "screen_time_limit", targetRole: "child",
          });
          console.log(
              `Screen time limit → child: ${sentCount} sent,`,
              "family:", familyId, "limit:", afterLimit,
          );
        } else if (updatedByRole === "child") {
          const title = "Child changed screen time";
          const body = `Screen time limit changed to ${afterLimit} minutes`;
          const sentCount = await sendPushToFamilyRole(
              db, familyId, "parent", title, body,
              {type: "child_screen_time_request", familyId, limitMinutes: String(afterLimit)},
          );
          await writeNotificationDoc(db, familyId, {
            title, body, type: "child_screen_time_request", targetRole: "parent",
          });
          console.log(
              `Child screen time request → parent: ${sentCount} sent,`,
              "family:", familyId,
          );
        }
      } catch (err) {
        console.error("notifyOnScreenTimeLimitChange failed:", err);
      }

      return null;
    });

// ── Trigger: child updates mood emoji → notify parent ─────────────────────────

exports.notifyOnMoodUpdate = functions.firestore
    .document("families/{familyId}/accounts/{accountId}/dailyData/{dateKey}")
    .onWrite(async (change, context) => {
      const after = change.after.exists ? change.after.data() : null;
      const before = change.before.exists ? change.before.data() : null;

      if (!after || !after.mood) return null;
      if (before && before.mood === after.mood) return null;

      const familyId = context.params.familyId;
      const accountId = context.params.accountId;
      const db = admin.firestore();

      // Only notify parent when the child updates their mood
      const accountDoc = await db
          .collection("families").doc(familyId)
          .collection("accounts").doc(accountId)
          .get();

      if (!accountDoc.exists) return null;
      if (accountDoc.data().role !== "child") return null;

      const emoji = after.mood;
      const title = "Child updated their mood";
      const body = `Mood for today: ${emoji}`;

      try {
        const sentCount = await sendPushToFamilyRole(
            db, familyId, "parent", title, body,
            {type: "mood_update", familyId},
        );
        await writeNotificationDoc(db, familyId, {
          title, body, type: "mood_update", targetRole: "parent",
        });
        console.log(
            `notifyOnMoodUpdate: sent ${sentCount} to parent(s), family: ${familyId}`,
        );
      } catch (err) {
        console.error("notifyOnMoodUpdate failed:", err);
      }

      return null;
    });

// ── Trigger: session ends → notify both parent and child ─────────────────────

exports.notifyOnSessionEnded = functions.firestore
    .document("families/{familyId}/sessions/{sessionId}")
    .onWrite(async (change, context) => {
      const after = change.after.exists ? change.after.data() : null;
      const before = change.before.exists ? change.before.data() : null;

      if (!after) return null;

      const endedStatuses = ["completed", "completed_override"];
      const wasEnded = before && endedStatuses.includes(before.status);
      const isEnded = endedStatuses.includes(after.status);
      // startTime is only set once a session actually starts (see
      // _startSession in session_tab.dart) — a pending session cancelled
      // before ever starting reuses "completed" as its status too, but
      // that's not a real session ending and shouldn't notify anyone.
      if (!isEnded || wasEnded || !after.startTime) return null;

      const familyId = context.params.familyId;
      const db = admin.firestore();
      const title = "Session ended";
      const body = "The screen time session has ended.";

      try {
        const [parentSent, childSent] = await Promise.all([
          sendPushToFamilyRole(db, familyId, "parent", title, body,
              {type: "session_ended", familyId}),
          sendPushToFamilyRole(db, familyId, "child", title, body,
              {type: "session_ended", familyId}),
        ]);
        await Promise.all([
          writeNotificationDoc(db, familyId, {
            title, body, type: "session_ended", targetRole: "parent",
          }),
          writeNotificationDoc(db, familyId, {
            title, body, type: "session_ended", targetRole: "child",
          }),
        ]);
        console.log(
            `notifyOnSessionEnded: parent=${parentSent} child=${childSent}`,
            "family:", familyId,
        );
      } catch (err) {
        console.error("notifyOnSessionEnded failed:", err);
      }

      // Reset today's screen-time bar and the limit-reached flag now that the
      // session is over. screenTimeLimitMinutes is per-session (equal to that
      // session's duration), so leftover usedMinutes/limitReachedAt from this
      // session must not carry into the next one or bleed into future app
      // opens — otherwise the client re-fires "limit reached" on every login
      // since limitReachedAt/limitReachedDateKey never change while stale.
      const dateKey = after.dateKey;
      if (dateKey) {
        try {
          await Promise.all([
            db.collection("families").doc(familyId)
                .collection("dashboard_days").doc(dateKey)
                .set({
                  screenTimeUsedMinutes: 0,
                  screenTimeLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
                }, {merge: true}),
            db.collection("families").doc(familyId)
                .collection("settings").doc("screenTime")
                .set({
                  limitReachedAt: admin.firestore.FieldValue.delete(),
                  limitReachedDateKey: admin.firestore.FieldValue.delete(),
                }, {merge: true}),
          ]);
          console.log(`notifyOnSessionEnded: reset screen time for family ${familyId}, date ${dateKey}`);
        } catch (err) {
          console.error("notifyOnSessionEnded reset failed:", err);
        }
      }

      return null;
    });

// ── Scheduled: silently wake iOS child devices with active sessions ──────────
// so the MAIN APP (not the short-lived DeviceActivityMonitor extension) can
// relay real screen-time minutes to Firestore even while KTB is backgrounded.
// The extension's own local App Group write is always accurate (confirmed by
// testing) — only its own network hop is unreliable, because the extension
// process is torn down by iOS almost immediately after firing. A full app
// woken by a silent push gets a real background-execution budget via
// application(_:didReceiveRemoteNotification:fetchCompletionHandler:), which
// is enough time to read that same App Group value and PATCH it to Firestore
// over the normal, reliable network path.
//
// This can only wake an app that's backgrounded, not one the user has
// force-quit — iOS blocks all background wake-ups (silent push included)
// after an explicit force-quit until the app is manually reopened. That's a
// hard platform limit with no workaround, not a gap in this function.
exports.relayActiveSessionScreenTime = functions.pubsub
    .schedule("every 1 minutes")
    .onRun(async () => {
      const db = admin.firestore();

      const activeSnap = await db.collectionGroup("sessions")
          .where("status", "==", "active")
          .get();

      const familyIds = new Set();
      activeSnap.forEach((doc) => {
        familyIds.add(doc.ref.parent.parent.id);
      });

      if (familyIds.size === 0) return null;

      let sent = 0;
      for (const familyId of familyIds) {
        try {
          const accountsSnap = await db
              .collection("families").doc(familyId)
              .collection("accounts")
              .where("role", "==", "child")
              .get();

          for (const accountDoc of accountsSnap.docs) {
            const deviceSnap = await db.collection("device_registrations")
                .where("familyId", "==", familyId)
                .where("accountId", "==", accountDoc.id)
                .where("platform", "==", "ios")
                .limit(1)
                .get();

            if (deviceSnap.empty) continue;
            const fcmToken = deviceSnap.docs[0].data().fcmToken;
            if (!fcmToken) continue;

            await admin.messaging().send({
              token: fcmToken,
              data: {type: "screentime_relay", familyId},
              apns: {
                headers: {"apns-priority": "5", "apns-push-type": "background"},
                payload: {aps: {"content-available": 1}},
              },
            });
            sent++;
          }
        } catch (err) {
          console.error(`relayActiveSessionScreenTime failed for family ${familyId}:`, err.message);
        }
      }
      console.log(`relayActiveSessionScreenTime: sent ${sent} silent push(es)`);
      return null;
    });

console.log("index.js finished loading");
