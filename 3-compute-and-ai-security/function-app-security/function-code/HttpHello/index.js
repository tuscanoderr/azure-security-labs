// HTTP trigger protected by a function key (authLevel "function").
// It logs each call so the request shows up in the live log stream.
module.exports = async function (context, req) {
  const name = req.query.name || "anonymous";
  context.log(`HttpHello called for ${name}`);
  context.res = {
    status: 200,
    body: `Hello ${name}, from a function app that reaches its storage with a managed identity.`
  };
};
