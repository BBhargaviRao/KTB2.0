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

Also write a "conversationStarter": a single simple, warm, low-pressure
question the parent could ask their child OUT LOUD in person tonight —
distinct from parentPrompt (which the parent answers privately in the app).
It should feel like a natural conversation opener, not an interrogation.
Same privacy rules apply: no specifics, no quotes, no platform/game names.

Return JSON only:
{
  "contextType": "positive | challenging | neutral",
  "parentPrompt": "...",
  "conversationStarter": "..."
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
    conversationStarter: parsed.conversationStarter || null,
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

    // Age-tiered: keyed by bracket ("6_7", "8_9", "10_11") — see
    // getChildAgeGroup(). Wording gets simpler/more concrete for younger
    // brackets and more reflective/open-ended for older ones. Each question
    // carries a "category" used by the adaptive weighting in
    // pickPromptForAccount (goal-matching, screen-time context, variety).
    child_afternoon: {
      "6_7": [
        {id: "a67_1", category: "mood_and_feelings", variant: "happy_or_grumpy", source: "library",
          text: "Was today a happy screen day or a grumpy screen day?"},
        {id: "a67_2", category: "specific_activity", variant: "made_you_smile", source: "library",
          text: "What game or show made you smile today?"},
        {id: "a67_3", category: "specific_activity", variant: "something_new", source: "library",
          text: "Did you watch or play something new today?"},
        {id: "a67_4", category: "social_online", variant: "talked_or_played_with", source: "library",
          text: "Who did you talk to or play with online today, if anyone?"},
        {id: "a67_5", category: "mood_and_feelings", variant: "mad_or_upset", source: "library",
          text: "Did a screen game or show ever make you feel mad or upset today?"},
        {id: "a67_6", category: "specific_activity", variant: "favorite_thing", source: "library",
          text: "What was your favorite thing you did on a screen today?"},
        {id: "a67_7", category: "balance_and_limits", variant: "asked_permission", source: "library",
          text: "Did you ask a grown-up before using a new app or game today?"},
        {id: "a67_8", category: "balance_and_limits", variant: "easy_or_hard_to_stop", source: "library",
          text: "Was it easy or hard to stop when your screen time was over?"},
        {id: "a67_9", category: "specific_activity", variant: "learned_something", source: "library",
          text: "Did you learn a new word, fact, or trick from a screen today?",
          example: "a new song, a fun animal fact, a game trick"},
        {id: "a67_10", category: "balance_and_limits", variant: "screen_vs_outside", source: "library",
          text: "Would you rather play outside or on a screen right now?"},
        {id: "a67_11", category: "social_online", variant: "shared_or_took_turns", source: "library",
          text: "Did you share your screen or take turns with anyone today?"},
        {id: "a67_12", category: "specific_activity", variant: "silly_thing", source: "library",
          text: "What's one silly thing that happened on a screen today?"},
        {id: "a67_13", category: "mood_and_feelings", variant: "excited_bored_sleepy", source: "library",
          text: "Did you feel excited, bored, or sleepy while using your screen today?"},
        {id: "a67_14", category: "mood_and_feelings", variant: "scared_or_weird", source: "library",
          text: "Did anything on your screen scare you or make you feel weird today?"},
        {id: "a67_15", category: "balance_and_limits", variant: "one_thing_tomorrow", source: "library",
          text: "If you could only do ONE screen thing tomorrow, what would you pick?"},
      ],
      "8_9": [
        {id: "a89_1", category: "mood_and_feelings", variant: "feelings_check", source: "library",
          text: "How are you feeling about your screen time so far today?"},
        {id: "a89_2", category: "specific_activity", variant: "most_time_spent", source: "library",
          text: "What app or game did you spend the most time on today?"},
        {id: "a89_3", category: "mood_and_feelings", variant: "good_moment", source: "library",
          text: "Did anything online make you laugh, smile, or feel good today?"},
        {id: "a89_4", category: "specific_activity", variant: "made_or_learned", source: "library",
          text: "Did you learn or make anything using a screen today?"},
        {id: "a89_5", category: "social_online", variant: "friends_online", source: "library",
          text: "Have you talked to any friends online today? What about?"},
        {id: "a89_6", category: "balance_and_limits", variant: "too_long_moment", source: "library",
          text: "Was there a moment today you felt like you were on your screen too long?"},
        {id: "a89_7", category: "reflection_and_growth", variant: "confused_or_curious", source: "library",
          text: "Did you see anything online today that confused you or made you curious?"},
        {id: "a89_8", category: "specific_activity", variant: "most_interesting", source: "library",
          text: "What's the most interesting thing you've done on a screen today?"},
        {id: "a89_9", category: "balance_and_limits", variant: "asked_permission", source: "library",
          text: "Did you ask permission before trying a new app or game today?"},
        {id: "a89_10", category: "mood_and_feelings", variant: "chill_vs_chaotic", source: "library",
          text: "On a scale of chill to chaotic, how has your screen time felt today?"},
        {id: "a89_11", category: "balance_and_limits", variant: "took_breaks", source: "library",
          text: "Did you take any breaks between screen activities today?"},
        {id: "a89_12", category: "social_online", variant: "unkind_comment", source: "library",
          text: "Has anyone said anything online today that felt unkind?",
          example: "teasing in a game chat, a rude comment"},
        {id: "a89_13", category: "balance_and_limits", variant: "rather_be_doing", source: "library",
          text: "What would you rather be doing right now if not on a screen?"},
        {id: "a89_14", category: "balance_and_limits", variant: "tasks_before_or_after", source: "library",
          text: "Did you finish your other tasks before or after screen time today?"},
        {id: "a89_15", category: "specific_activity", variant: "wish_more_of", source: "library",
          text: "What's one game or app you wish you could use more of today?"},
        {id: "a89_16", category: "reflection_and_growth", variant: "reward_or_habit", source: "library",
          text: "Did today's screen time feel like a reward or just a habit?"},
      ],
      "10_11": [
        {id: "a1011_1", category: "reflection_and_growth", variant: "relationship_with_screens", source: "library",
          text: "How would you describe your relationship with your screen time today so far?"},
        {id: "a1011_2", category: "reflection_and_growth", variant: "worthwhile_thing", source: "library",
          text: "What's one thing you did on a screen today that felt genuinely worthwhile?"},
        {id: "a1011_3", category: "reflection_and_growth", variant: "scrolling_without_thinking", source: "library",
          text: "Did you notice yourself scrolling or switching apps without really thinking about it today?"},
        {id: "a1011_4", category: "mood_and_feelings", variant: "shaped_your_mood", source: "library",
          text: "Has anything you've seen online today shaped your mood, positively or negatively?"},
        {id: "a1011_5", category: "social_online", variant: "online_vs_in_person", source: "library",
          text: "Did a conversation with a friend online today feel different from talking in person?"},
        {id: "a1011_6", category: "reflection_and_growth", variant: "made_you_think", source: "library",
          text: "What's something you saw today that made you think, even if just for a second?"},
        {id: "a1011_7", category: "balance_and_limits", variant: "matched_what_wanted", source: "library",
          text: "Do you feel like today's screen time matched what you actually wanted to do, or did you just default to it?"},
        {id: "a1011_8", category: "social_online", variant: "compared_to_someone", source: "library",
          text: "Has anything online today made you compare yourself to someone else?",
          example: "how someone looks, what they own, what they've achieved"},
        {id: "a1011_9", category: "reflection_and_growth", variant: "change_if_redo", source: "library",
          text: "What's one thing you'd change about how you're using screens today if you could redo it?"},
        {id: "a1011_10", category: "reflection_and_growth", variant: "present_or_distracted", source: "library",
          text: "Did you feel present in what you were doing on your screen, or distracted the whole time?"},
        {id: "a1011_11", category: "balance_and_limits", variant: "planned_vs_actual", source: "library",
          text: "Is there a difference between what you planned to do on your screen today and what you actually did?"},
        {id: "a1011_12", category: "reflection_and_growth", variant: "usage_patterns", source: "library",
          text: "Have you noticed any patterns in when you reach for a screen — boredom, stress, habit?"},
        {id: "a1011_13", category: "specific_activity", variant: "curious_to_explore", source: "library",
          text: "What's something you're curious about that you could look into today?"},
        {id: "a1011_14", category: "balance_and_limits", variant: "personal_limit", source: "library",
          text: "Did you set any personal limit today, and did you stick to it?"},
        {id: "a1011_15", category: "balance_and_limits", variant: "choice_or_autopilot", source: "library",
          text: "Has your screen time today felt more like a choice or more like autopilot?"},
        {id: "a1011_16", category: "social_online", variant: "what_peers_care_about", source: "library",
          text: "What's one thing happening online right now that people your age seem to care about?"},
      ],
    },

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

    child_night: {
      "6_7": [
        {id: "n67_1", category: "gratitude_and_connection", variant: "best_part_of_day", source: "library",
          text: "What was the best part of your day, screen or not?"},
        {id: "n67_2", category: "balance_and_limits", variant: "screen_vs_other_fun", source: "library",
          text: "Did you have more fun on a screen or doing something else today?"},
        {id: "n67_3", category: "mood_and_feelings", variant: "made_you_laugh", source: "library",
          text: "What's one thing that made you laugh today?"},
        {id: "n67_4", category: "balance_and_limits", variant: "happy_with_amount", source: "library",
          text: "Are you happy with how much screen time you had today?"},
        {id: "n67_5", category: "gratitude_and_connection", variant: "helped_or_played_nicely", source: "library",
          text: "Did you help someone or play nicely with someone today?"},
        {id: "n67_6", category: "reflection_and_growth", variant: "tomorrow_plan", source: "library",
          text: "What do you want to do tomorrow — same screen stuff or something new?"},
        {id: "n67_7", category: "wind_down", variant: "felt_tired", source: "library",
          text: "Did you feel tired after your screen time today?"},
        {id: "n67_8", category: "gratitude_and_connection", variant: "thankful_for", source: "library",
          text: "What's one thing you're thankful for from today?"},
        {id: "n67_9", category: "gratitude_and_connection", variant: "kind_to_family", source: "library",
          text: "Did you do anything kind for your family today?"},
        {id: "n67_10", category: "gratitude_and_connection", variant: "tell_parent", source: "library",
          text: "Was there a moment today you want to tell your parent about?"},
        {id: "n67_11", category: "balance_and_limits", variant: "screen_free_too", source: "library",
          text: "Did you read a book or do something screen-free today too?"},
        {id: "n67_12", category: "specific_activity", variant: "funniest_thing", source: "library",
          text: "What's the funniest thing you saw on a screen today?",
          example: "a funny video, a silly game character"},
        {id: "n67_13", category: "wind_down", variant: "calm_or_excited", source: "library",
          text: "Do you feel calm and ready for bed, or still excited?"},
        {id: "n67_14", category: "balance_and_limits", variant: "followed_rules", source: "library",
          text: "Did you play a game with rules today, and did you follow them?"},
        {id: "n67_15", category: "reflection_and_growth", variant: "do_differently", source: "library",
          text: "What's one thing you want to do differently tomorrow?"},
      ],
      "8_9": [
        {id: "n89_1", category: "specific_activity", variant: "best_part_of_screen_time", source: "library",
          text: "Looking back, what was the best part of your screen time today?"},
        {id: "n89_2", category: "balance_and_limits", variant: "balanced_other_things", source: "library",
          text: "Did you balance screens with other things today, like playing outside or reading?"},
        {id: "n89_3", category: "gratitude_and_connection", variant: "grateful_for", source: "library",
          text: "What's something you're grateful for from today?"},
        {id: "n89_4", category: "reflection_and_growth", variant: "in_control", source: "library",
          text: "Did you feel like you were in control of your screen time today, or did it control you?"},
        {id: "n89_5", category: "balance_and_limits", variant: "screen_free_moment_enjoyed", source: "library",
          text: "Was there a screen-free moment today you actually enjoyed?"},
        {id: "n89_6", category: "reflection_and_growth", variant: "stuck_in_mind", source: "library",
          text: "Did anything you saw or played today stick in your mind afterward?"},
        {id: "n89_7", category: "wind_down", variant: "mood_by_end_of_day", source: "library",
          text: "How did your screen time affect your mood by the end of the day?"},
        {id: "n89_8", category: "gratitude_and_connection", variant: "helped_family", source: "library",
          text: "Did you help anyone in your family today, on a screen or off?"},
        {id: "n89_9", category: "reflection_and_growth", variant: "try_differently", source: "library",
          text: "What's one thing you want to try differently with screens tomorrow?"},
        {id: "n89_10", category: "wind_down", variant: "rushed_or_relaxed", source: "library",
          text: "Did you feel rushed or relaxed during your screen time today?"},
        {id: "n89_11", category: "balance_and_limits", variant: "spending_too_much_time", source: "library",
          text: "Is there a game or show you think you're spending too much time on lately?"},
        {id: "n89_12", category: "social_online", variant: "tell_a_friend", source: "library",
          text: "What's a moment from today — on a screen or not — you'd want to tell a friend about?"},
        {id: "n89_13", category: "reflection_and_growth", variant: "kept_promises", source: "library",
          text: "Did you keep any promises you made about your screen time today?"},
        {id: "n89_14", category: "reflection_and_growth", variant: "noticed_about_self", source: "library",
          text: "What's something new you noticed about yourself today?"},
        {id: "n89_15", category: "gratitude_and_connection", variant: "looking_forward", source: "library",
          text: "Are you looking forward to anything tomorrow, screen-related or not?"},
        {id: "n89_16", category: "reflection_and_growth", variant: "good_screen_day_overall", source: "library",
          text: "Did today feel like a \"good screen day\" overall? Why or why not?"},
      ],
      "10_11": [
        {id: "n1011_1", category: "reflection_and_growth", variant: "relationship_with_screens", source: "library",
          text: "Looking back at today, how would you describe your relationship with screens?"},
        {id: "n1011_2", category: "social_online", variant: "helped_or_hindered_connection", source: "library",
          text: "Did screens help you connect with people today, or did they get in the way of connecting?"},
        {id: "n1011_3", category: "reflection_and_growth", variant: "surprised_you", source: "library",
          text: "What's one thing you noticed about your own habits today that surprised you?"},
        {id: "n1011_4", category: "reflection_and_growth", variant: "value_vs_filler", source: "library",
          text: "Do you think today's screen time added value to your day, or was some of it just filler?"},
        {id: "n1011_5", category: "balance_and_limits", variant: "chose_not_to_check", source: "library",
          text: "Was there a moment today when you chose NOT to check something, even though you wanted to?"},
        {id: "n1011_6", category: "wind_down", variant: "more_like_yourself", source: "library",
          text: "Did you feel more like yourself when you were off your screen today, or on it?"},
        {id: "n1011_7", category: "gratitude_and_connection", variant: "proud_of", source: "library",
          text: "What's something you're proud of from today, screen-related or not?"},
        {id: "n1011_8", category: "reflection_and_growth", variant: "think_about_total_time", source: "library",
          text: "Did anything today make you think about how much time you spend on your screen overall?"},
        {id: "n1011_9", category: "balance_and_limits", variant: "own_boundary", source: "library",
          text: "Is there a boundary around screens you want to set for yourself, not just one your parents set?"},
        {id: "n1011_10", category: "reflection_and_growth", variant: "intentional_tomorrow", source: "library",
          text: "What's one thing you want to be more intentional about tomorrow?"},
        {id: "n1011_11", category: "wind_down", variant: "felt_after_putting_down", source: "library",
          text: "Did you notice how you felt right after putting your screen down today?"},
        {id: "n1011_12", category: "gratitude_and_connection", variant: "screen_free_meaningful", source: "library",
          text: "Was there a screen-free part of today that ended up being more meaningful than you expected?"},
        {id: "n1011_13", category: "reflection_and_growth", variant: "focused_or_scattered", source: "library",
          text: "Do you think you were more focused or more scattered today because of your screen use?"},
        {id: "n1011_14", category: "social_online", variant: "question_wish_asked", source: "library",
          text: "What's a question you wish someone would ask you about your online life?"},
        {id: "n1011_15", category: "reflection_and_growth", variant: "healthy_or_not", source: "library",
          text: "If you described today's screen time to a friend, would you call it healthy, or not really?"},
        {id: "n1011_16", category: "reflection_and_growth", variant: "learned_about_self", source: "library",
          text: "What's one small thing you learned about yourself today?"},
      ],
    },
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

// Maps a parent-selected family goal (see "Set Child Details" UI) to the
// question category it should mildly favor. "wind_down" doubles as its own
// category (night-window sleep/calm questions) rather than folding into
// mood_and_feelings, so the goal has something distinct to boost.
const GOAL_CATEGORY_MAP = {
  less_gaming: "balance_and_limits",
  wind_down: "wind_down",
  more_connection: "social_online",
  more_creativity: "specific_activity",
  more_reflection: "reflection_and_growth",
};

function ageToGroup(age) {
  const n = Number(age);
  if (!Number.isFinite(n)) return "8_9";
  if (n <= 7) return "6_7";
  if (n <= 9) return "8_9";
  return "10_11";
}

// Weighted random pick — used instead of a hard filter so "adaptive" biasing
// (goals, screen-time context, category variety) never collapses the
// eligible set down to just one or two options and starts feeling robotic.
function pickWeighted(items, weightFn) {
  if (!items || !items.length) return null;
  const weights = items.map((item) => Math.max(0, weightFn(item)));
  const total = weights.reduce((a, b) => a + b, 0);
  if (total <= 0) return pickRandom(items);
  let r = Math.random() * total;
  for (let i = 0; i < items.length; i++) {
    r -= weights[i];
    if (r <= 0) return items[i];
  }
  return items[items.length - 1];
}

// context: {ageGroup, familyGoals, screenTimeRatio}
// - ageGroup selects which child_afternoon/child_night bracket to read from
//   (parent_morning/parent_evening are flat arrays and ignore ageGroup).
// - familyGoals (array of GOAL_CATEGORY_MAP keys) mildly boosts matching
//   categories.
// - screenTimeRatio (0-1, today's used/limit minutes) mildly boosts
//   balance_and_limits questions on a heavy-usage day.
// - Previous-answer adaptiveness: mildly de-weights repeating the exact
//   category of this account+window's last nudge, on top of the existing
//   hard exclusion of recently-used exact question ids.
async function pickPromptForAccount(
    db,
    familyId,
    accountId,
    deliveryWindow,
    context = {},
) {
  const {ageGroup, familyGoals, screenTimeRatio} = context;
  const promptBank = getPromptBank();
  const bankEntry = promptBank[deliveryWindow];
  const prompts = Array.isArray(bankEntry) ?
    bankEntry :
    (bankEntry ? (bankEntry[ageGroup] || bankEntry["8_9"] || []) : []);

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

  const recentDocs = recentSnapshot.docs.map((doc) => doc.data());
  const recentPromptIds = new Set(
      recentDocs.map((d) => d.promptId).filter((id) => !!id),
  );
  const previousCategory = recentDocs.length > 0 ?
    recentDocs[0].promptCategory :
    null;

  let eligiblePrompts = prompts;

  if (recentPromptIds.size > 0) {
    const filtered = prompts.filter(
        (prompt) => !recentPromptIds.has(prompt.id),
    );

    if (filtered.length > 0) {
      eligiblePrompts = filtered;
    }
  }

  const goalCategories = new Set(
      (familyGoals || []).map((g) => GOAL_CATEGORY_MAP[g]).filter(Boolean),
  );
  const contextCategory = (typeof screenTimeRatio === "number" && screenTimeRatio >= 0.75) ?
    "balance_and_limits" :
    null;

  return pickWeighted(eligiblePrompts, (prompt) => {
    let weight = 1;
    if (goalCategories.has(prompt.category)) weight += 2;
    if (contextCategory && prompt.category === contextCategory) weight += 1;
    if (previousCategory && prompt.category === previousCategory) weight *= 0.4;
    return weight;
  });
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

// Reads the parent-configured delivery windows, child age bracket, and
// family goals from families/{familyId}/settings/nudges (all set together
// via the "Set Child Details" UI in the Nudges tab, one Firestore doc/read).
// Falls back to defaults for anything not yet customized. Only the child's
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
      return {...DEFAULT_CHILD_WINDOWS, ageGroup: "8_9", familyGoals: []};
    }

    const data = doc.data() || {};
    return {
      child_afternoon: data.childWindow1 || DEFAULT_CHILD_WINDOWS.child_afternoon,
      child_night: data.childWindow2 || DEFAULT_CHILD_WINDOWS.child_night,
      ageGroup: ageToGroup(data.childAge),
      familyGoals: Array.isArray(data.familyGoals) ? data.familyGoals : [],
    };
  } catch (err) {
    console.error("Failed to read nudge window settings, using defaults:", err);
    return {...DEFAULT_CHILD_WINDOWS, ageGroup: "8_9", familyGoals: []};
  }
}

// Today's used/limit minutes ratio (0-1), used to mildly favor
// balance_and_limits questions on a heavy-usage day. Returns null (no bias)
// if either value is missing — a new/short day shouldn't read as "light usage".
async function getScreenTimeRatio(db, familyId, dateKey) {
  try {
    const [daySnap, settingsSnap] = await Promise.all([
      db.collection("families").doc(familyId)
          .collection("dashboard_days").doc(dateKey).get(),
      db.collection("families").doc(familyId)
          .collection("settings").doc("screenTime").get(),
    ]);
    const used = daySnap.exists ? daySnap.data().screenTimeUsedMinutes : null;
    const limit = settingsSnap.exists ? settingsSnap.data().screenTimeLimitMinutes : null;
    if (typeof used !== "number" || typeof limit !== "number" || limit <= 0) {
      return null;
    }
    return used / limit;
  } catch (err) {
    console.error("Failed to compute screen time ratio:", err);
    return null;
  }
}

// dateKey is "yyyy-MM-dd" — returns the same format for the previous day,
// via plain date math (UTC-safe since we only care about the calendar date,
// not time-of-day).
function previousDateKey(dateKey) {
  const [y, m, d] = dateKey.split("-").map(Number);
  const date = new Date(Date.UTC(y, m - 1, d));
  date.setUTCDate(date.getUTCDate() - 1);
  const yy = date.getUTCFullYear();
  const mm = String(date.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(date.getUTCDate()).padStart(2, "0");
  return `${yy}-${mm}-${dd}`;
}

// Simple reward: consecutive-day streak of answering at least one nudge.
// Keyed off the NUDGE's own dateKey (not "today" server-side) so it stays
// consistent with everything else that's keyed the same way (changeNudgePrompt,
// dashboard_days, etc.) rather than introducing a third notion of "today".
async function updateChildAnswerStreak(db, familyId, accountId, dateKey) {
  if (!dateKey) return;
  const accountRef = db.collection("families").doc(familyId)
      .collection("accounts").doc(accountId);

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(accountRef);
    const acct = snap.exists ? snap.data() : {};
    const lastKey = acct.lastAnsweredDateKey;

    if (lastKey === dateKey) {
      // Already counted an answer for this day — a second nudge answered
      // the same day doesn't add a second streak day.
      return;
    }

    const currentStreak = acct.answerStreak || 0;
    const newStreak = lastKey === previousDateKey(dateKey) ? currentStreak + 1 : 1;

    tx.set(accountRef, {
      answerStreak: newStreak,
      lastAnsweredDateKey: dateKey,
    }, {merge: true});
  });
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

          const screenTimeRatio = role === "child" ?
            await getScreenTimeRatio(db, familyId, dateKey) :
            null;

          for (const windowItem of windows) {
            const deliveryWindow = windowItem.deliveryWindow;
            const nudgeType = windowItem.nudgeType;

            const selectedPrompt = await pickPromptForAccount(
                db,
                familyId,
                account.id,
                deliveryWindow,
                {
                  ageGroup: childWindows.ageGroup,
                  familyGoals: childWindows.familyGoals,
                  screenTimeRatio,
                },
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
            let conversationStarter = null;

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
                    conversationStarter = result.conversationStarter || null;

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
                  conversationStarter: conversationStarter,
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

          const screenTimeRatio = role === "child" ?
            await getScreenTimeRatio(db, familyId, dateKey) :
            null;

          for (const windowItem of windows) {
            const deliveryWindow = windowItem.deliveryWindow;
            const nudgeType = windowItem.nudgeType;

            const selectedPrompt = await pickPromptForAccount(
                db,
                familyId,
                account.id,
                deliveryWindow,
                {
                  ageGroup: childWindows.ageGroup,
                  familyGoals: childWindows.familyGoals,
                  screenTimeRatio,
                },
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
            let conversationStarter = null;

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
                    conversationStarter = result.conversationStarter || null;

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
                  conversationStarter: conversationStarter,
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

      // Streak reward — independent of the emotion-analysis path below (and
      // of response text length), so it updates for every genuine answer.
      try {
        await updateChildAnswerStreak(
            admin.firestore(), context.params.familyId, after.targetAccountId, after.dateKey,
        );
      } catch (err) {
        console.error("updateChildAnswerStreak failed:", err);
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

// ── Browser-based family onboarding ───────────────────────────────────────────
// Visit this URL directly in a browser: it shows a form, and submitting it
// (a plain GET, so no CORS/body-parsing needed) creates a brand-new, fully
// isolated family — accounts under a fresh auto-ID familyRef, exactly like
// createStudyFamily — plus a seeded settings/nudges doc and two pending
// example nudges (one parent, one child) so there's something to answer
// immediately instead of waiting for the next day's 00:05 scheduled run.
// Isolation from other families is the same as everywhere else in this app
// (see firestore.rules): purely by familyId — nothing here changes that.

function _escapeHtml(s) {
  return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
}

function _onboardPageShell(bodyHtml) {
  return `<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>KTB — New Test Family</title>
<style>
  body { font-family: -apple-system, system-ui, sans-serif; background: #F5F3FF; color: #2D2B55;
         max-width: 480px; margin: 40px auto; padding: 0 20px; }
  h1 { font-size: 22px; }
  label { display: block; margin-top: 14px; font-weight: 600; font-size: 13px; color: #6E6A8E; }
  input { width: 100%; box-sizing: border-box; padding: 10px 12px; margin-top: 4px;
          border: 1px solid #E0DDEF; border-radius: 10px; font-size: 15px; }
  button { margin-top: 22px; width: 100%; padding: 13px; border: none; border-radius: 10px;
           background: #7C6FCD; color: white; font-size: 15px; font-weight: 600; cursor: pointer; }
  .error { background: #FFEBEE; color: #C0392B; padding: 10px 14px; border-radius: 10px;
           margin-top: 16px; font-size: 13px; }
  .card { background: white; padding: 16px 18px; border-radius: 14px; margin-top: 12px;
          border: 1px solid #E0DDEF; }
  .row { display: flex; justify-content: space-between; padding: 6px 0; font-size: 14px; }
  .row b { color: #6E6A8E; font-weight: 600; }
  .pill { font-family: monospace; font-size: 20px; letter-spacing: 2px; font-weight: 700; }
</style></head><body>${bodyHtml}</body></html>`;
}

function _renderOnboardForm({error, parentName, childName} = {}) {
  return _onboardPageShell(`
    <h1>Create a new test family</h1>
    <p style="color:#6E6A8E; font-size:13px;">Creates an isolated family — its own family code, parent + child login PIN, and a couple of example nudges to test with right away.</p>
    ${error ? `<div class="error">${_escapeHtml(error)}</div>` : ""}
    <form method="GET">
      <label>Parent name</label>
      <input name="parentName" required value="${_escapeHtml(parentName || "")}">
      <label>Parent PIN (4 digits)</label>
      <input name="parentPin" required pattern="\\d{4}" inputmode="numeric" maxlength="4">
      <label>Child name</label>
      <input name="childName" required value="${_escapeHtml(childName || "")}">
      <label>Child PIN (4 digits)</label>
      <input name="childPin" required pattern="\\d{4}" inputmode="numeric" maxlength="4">
      <button type="submit">Create Family</button>
    </form>
  `);
}

function _renderOnboardSuccess({familyId, familyCode, parentName, parentPin, childName, childPin}) {
  return _onboardPageShell(`
    <h1>Family created ✅</h1>
    <div class="card">
      <div class="row"><span>Family code</span><b class="pill">${_escapeHtml(familyCode)}</b></div>
    </div>
    <div class="card">
      <div class="row"><span>Parent</span><b>${_escapeHtml(parentName)}</b></div>
      <div class="row"><span>Parent PIN</span><b>${_escapeHtml(parentPin)}</b></div>
      <div class="row"><span>Child</span><b>${_escapeHtml(childName)}</b></div>
      <div class="row"><span>Child PIN</span><b>${_escapeHtml(childPin)}</b></div>
    </div>
    <p style="color:#6E6A8E; font-size:12px;">familyId: ${_escapeHtml(familyId)}</p>
    <p style="font-size:13px;">Open the KTB app, enter the family code and PIN above on either device to log in. Both parent and child already have a pending example nudge ready to answer (including a voice answer, on the child side).</p>
    <a href="?"><button type="button" style="margin-top:8px;">Create another family</button></a>
  `);
}

exports.onboardFamily = functions.https.onRequest(async (req, res) => {
  const {parentName, childName, parentPin, childPin} = req.query;

  if (!parentName || !childName || !parentPin || !childPin) {
    return res.status(200).send(_renderOnboardForm());
  }

  const pinRe = /^\d{4}$/;
  if (!pinRe.test(String(parentPin)) || !pinRe.test(String(childPin))) {
    return res.status(200).send(_renderOnboardForm({
      error: "PIN must be exactly 4 digits.", parentName, childName,
    }));
  }
  if (!String(parentName).trim() || !String(childName).trim()) {
    return res.status(200).send(_renderOnboardForm({error: "Names cannot be empty."}));
  }

  try {
    const db = admin.firestore();
    const familyCode = await generateUniqueFamilyCode(db);

    const familyRef = db.collection("families").doc();
    const parentRef = familyRef.collection("accounts").doc("p1");
    const childRef = familyRef.collection("accounts").doc("c1");

    await familyRef.set({
      familyCode,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      studyStatus: "active",
    });
    await parentRef.set({
      displayName: String(parentName).trim(),
      role: "parent",
      pin: String(parentPin),
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    await childRef.set({
      displayName: String(childName).trim(),
      role: "child",
      pin: String(childPin),
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // Sane defaults so generateDailyNudges (age-based prompt selection,
    // family-goal weighting) behaves reasonably from day one instead of
    // falling back to its "no settings doc yet" defaults.
    await familyRef.collection("settings").doc("nudges").set({
      childAge: 10,
      familyGoals: [],
      childWindow1: {startHour: 15, endHour: 17},
      childWindow2: {startHour: 20, endHour: 21},
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedByRole: "system",
    });

    const {dateKey} = getLocalTimeParts();
    const now = admin.firestore.Timestamp.now();
    const baseNudge = {
      promptVariant: "seed",
      promptSource: "library",
      promptGenerationMode: "library",
      conversationStarter: null,
      dateKey,
      status: "pending",
      notificationStatus: "not_sent",
      notificationSentAt: null,
      openedAt: null,
      answeredAt: null,
      ignoredAt: null,
      responseLatencySeconds: null,
      openLatencySeconds: null,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      scheduledFor: now,
    };
    await familyRef.collection("nudges").add({
      ...baseNudge,
      prompt: "How are things going with screen time today?",
      promptText: "How are things going with screen time today?",
      promptId: "onboard_seed_parent_1",
      promptCategory: "check_in",
      targetAccountId: "p1",
      targetRole: "parent",
      nudgeType: "check_in",
      deliveryWindow: "parent_morning",
    });
    await familyRef.collection("nudges").add({
      ...baseNudge,
      prompt: "What was the best part of your day?",
      promptText: "What was the best part of your day?",
      promptId: "onboard_seed_child_1",
      promptCategory: "reflection_and_growth",
      targetAccountId: "c1",
      targetRole: "child",
      nudgeType: "reflection",
      deliveryWindow: "child_afternoon",
    });

    return res.status(200).send(_renderOnboardSuccess({
      familyId: familyRef.id,
      familyCode,
      parentName: String(parentName).trim(),
      parentPin: String(parentPin),
      childName: String(childName).trim(),
      childPin: String(childPin),
    }));
  } catch (error) {
    console.error("onboardFamily failed:", error);
    return res.status(200).send(_renderOnboardForm({
      error: `Something went wrong: ${error.message}`, parentName, childName,
    }));
  }
});

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
                  // Per-session limit (equal to that session's duration) —
                  // must not linger after the session ends, or the client
                  // dashboard keeps showing/evaluating against a stale cap.
                  screenTimeLimitMinutes: admin.firestore.FieldValue.delete(),
                }, {merge: true}),
          ]);
          console.log(`notifyOnSessionEnded: reset screen time for family ${familyId}, date ${dateKey}`);
        } catch (err) {
          console.error("notifyOnSessionEnded reset failed:", err);
        }
      }

      return null;
    });

// ── Scheduled: auto-complete sessions whose endTime has passed ───────────────
// _ActiveCard's countdown timer (session_tab.dart) is the only thing that
// normally marks an expired session "completed" — but it only runs while
// someone has the Session tab open. If nobody does, the session doc sits at
// status:"active" indefinitely: screenTimeUsedMinutes/screenTimeLimitMinutes
// never get reset (notifyOnSessionEnded above only fires on the completed
// transition), so the next login re-evaluates against that stale "at limit"
// state and re-fires the "screen time is up" notification even though
// nothing is actually running anymore. This sweep closes that gap
// server-side, independent of whether any device has the app open.
exports.autoCompleteOverdueSessions = functions.pubsub
    .schedule("every 5 minutes")
    .onRun(async () => {
      const db = admin.firestore();
      const now = admin.firestore.Timestamp.now();

      const activeSessions = await db.collectionGroup("sessions")
          .where("status", "==", "active")
          .get();

      const overdue = activeSessions.docs.filter((doc) => {
        const endTime = doc.data().endTime;
        return endTime && endTime.toMillis() <= now.toMillis();
      });

      if (overdue.length === 0) return null;

      await Promise.all(overdue.map((doc) => doc.ref.update({
        status: "completed",
      })));

      console.log(`autoCompleteOverdueSessions: closed ${overdue.length} session(s)`);
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

// ── Callable: "Change Question" — child can swap a pending nudge's question ──
// for a different one from the same age-appropriate bank, up to
// MAX_NUDGE_CHANGES_PER_DAY times total per day (shared across both of the
// child's daily nudges, not per-nudge). The daily counter lives on
// families/{familyId}/dailyData/{dateKey}.nudgeChangeCount.{accountId},
// alongside the day's other todo/mood data, and is enforced inside a
// transaction so rapid double-taps can't exceed the limit.
const MAX_NUDGE_CHANGES_PER_DAY = 3;

exports.changeNudgePrompt = functions.https.onCall(async (data) => {
  const familyId = data.familyId;
  const accountId = data.accountId;
  const nudgeId = data.nudgeId;

  if (!familyId || !accountId || !nudgeId) {
    throw new functions.https.HttpsError(
        "invalid-argument", "Missing familyId, accountId, or nudgeId.",
    );
  }

  const db = admin.firestore();
  const nudgeRef = db.collection("families").doc(familyId)
      .collection("nudges").doc(nudgeId);

  const nudgeSnap = await nudgeRef.get();
  if (!nudgeSnap.exists) {
    throw new functions.https.HttpsError("not-found", "Nudge not found.");
  }
  const nudge = nudgeSnap.data();
  if (nudge.targetAccountId !== accountId) {
    throw new functions.https.HttpsError(
        "permission-denied", "This nudge does not belong to this account.",
    );
  }
  if (nudge.status !== "pending") {
    throw new functions.https.HttpsError(
        "failed-precondition", "This nudge has already been answered.",
    );
  }

  const dateKey = nudge.dateKey;
  const dailyDataRef = db.collection("families").doc(familyId)
      .collection("dailyData").doc(dateKey);

  return db.runTransaction(async (tx) => {
    const dailySnap = await tx.get(dailyDataRef);
    const changeCounts = (dailySnap.exists && dailySnap.data().nudgeChangeCount) || {};
    const used = changeCounts[accountId] || 0;

    if (used >= MAX_NUDGE_CHANGES_PER_DAY) {
      return {ok: false, reason: "limit_reached", remaining: 0};
    }

    const childWindows = await getChildNudgeWindows(db, familyId);
    const screenTimeRatio = await getScreenTimeRatio(db, familyId, dateKey);
    const newPrompt = await pickPromptForAccount(
        db, familyId, accountId, nudge.deliveryWindow,
        {
          ageGroup: childWindows.ageGroup,
          familyGoals: childWindows.familyGoals,
          screenTimeRatio,
        },
    );

    if (!newPrompt) {
      return {
        ok: false,
        reason: "no_prompt_available",
        remaining: MAX_NUDGE_CHANGES_PER_DAY - used,
      };
    }

    tx.update(nudgeRef, {
      prompt: newPrompt.text,
      promptText: newPrompt.text,
      promptId: newPrompt.id,
      promptCategory: newPrompt.category,
      promptVariant: newPrompt.variant,
      promptSource: newPrompt.source,
      promptGenerationMode: "library",
      changedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    tx.set(dailyDataRef, {
      nudgeChangeCount: {...changeCounts, [accountId]: used + 1},
    }, {merge: true});

    return {
      ok: true,
      remaining: MAX_NUDGE_CHANGES_PER_DAY - (used + 1),
      prompt: newPrompt.text,
    };
  });
});

console.log("index.js finished loading");
