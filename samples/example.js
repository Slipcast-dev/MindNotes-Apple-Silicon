// Fetches a user and prints a greeting.
async function greet(id) {
  const res = await fetch(`/api/users/${id}`);
  if (!res.ok) throw new Error('Request failed: ' + res.status);
  const { name } = await res.json();
  return `Hello, ${name}!`;
}

greet(42).then(console.log).catch(console.error);
