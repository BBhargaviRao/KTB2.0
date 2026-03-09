const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");

admin.initializeApp();

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

          const prompt =
          role === "child" ?
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

      const prompt =
        role === "child" ?
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
