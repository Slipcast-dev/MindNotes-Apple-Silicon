interface User {
  id: number;
  name: string;
  email?: string;
}

/** Returns the users whose name starts with the prefix. */
export function byPrefix(users: User[], prefix: string): User[] {
  return users.filter((u) => u.name.toLowerCase().startsWith(prefix.toLowerCase()));
}
