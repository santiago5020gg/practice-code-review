# Container-Presentational Pattern & TypeScript Strictness — Reference

## Extended Examples

### Rule 1: No Mixed Data-Fetching and Rendering

#### Edge Case: Trivially simple components
A component that calls `useSWR` but renders only a single value (e.g., a badge showing unread count) does NOT need splitting if the JSX is under ~10 lines and has no complex layout.

```typescript
// ACCEPTABLE — trivially simple, no split needed
export const UnreadBadge = (): JSX.Element => {
  const { data } = useSWR<number>('/api/unread-count', fetcher);
  return <span className="badge">{data ?? 0}</span>;
};
```

The threshold is "significant JSX" — maps, grids, complex conditional rendering, or multiple nested elements.

#### Edge Case: Pages as containers
Next.js page files (`pages/*.tsx`) act as top-level containers. They may call `getServerSideProps`/`getStaticProps` and compose components. This is acceptable — pages are containers by convention.

```typescript
// pages/products.tsx — this is fine, pages are containers
export const getServerSideProps: GetServerSideProps = async () => {
  const products = await fetchProducts();
  return { props: { products } };
};

const ProductsPage = ({ products }: ProductsPageProps): JSX.Element => (
  <Layout>
    <ProductList products={products} />
  </Layout>
);

export default ProductsPage;
```

### Rule 2: Presentational Components Must Be Pure

#### Edge Case: Local UI state is acceptable
Presentational components may use `useState` for local UI concerns like toggling a dropdown, managing focus, or controlling an animation. This is not a violation.

```typescript
// ACCEPTABLE — local UI state in a presentational component
interface AccordionProps {
  title: string;
  children: React.ReactNode;
}

const Accordion = ({ title, children }: AccordionProps): JSX.Element => {
  const [isOpen, setIsOpen] = useState(false);
  return (
    <div>
      <button onClick={() => setIsOpen(!isOpen)}>{title}</button>
      {isOpen && <div>{children}</div>}
    </div>
  );
};
```

#### Anti-Pattern: Business logic disguised as UI logic
Transforming, filtering, or sorting data inside a presentational component is business logic, not UI logic.

```typescript
// BAD — filtering is business logic
const UserList = ({ users }: UserListProps): JSX.Element => {
  const activeUsers = users.filter((u) => u.status === 'active' && u.lastLogin > thirtyDaysAgo);
  const sorted = activeUsers.sort((a, b) => b.karma - a.karma);
  return <ul>{sorted.map((u) => <UserRow key={u.id} user={u} />)}</ul>;
};

// GOOD — container or hook handles filtering
const UserList = ({ users }: UserListProps): JSX.Element => (
  <ul>{users.map((u) => <UserRow key={u.id} user={u} />)}</ul>
);
```

### Rule 3: Container Components Must Not Contain Complex JSX

#### Edge Case: Minimal wrapper markup is acceptable
Containers may include simple wrappers like `<div>` or `<section>` for layout purposes, and conditional rendering of loading/error states.

```typescript
// ACCEPTABLE — minimal wrapper
const UserProfileContainer = (): JSX.Element => {
  const { user, isLoading } = useUser();
  if (isLoading) return <LoadingSpinner />;
  return (
    <div className="page-wrapper">
      <UserProfile user={user} />
    </div>
  );
};
```

### Rule 4: No `any` Type

#### Edge Case: Third-party library without types
When a library lacks type definitions, create a local declaration file instead of using `any`.

```typescript
// types/untyped-lib.d.ts
declare module 'untyped-lib' {
  export function doThing(input: string): { result: string; status: number };
}
```

#### Edge Case: Event handlers with unknown payloads
Use `unknown` + type guards:

```typescript
const handleMessage = (payload: unknown): void => {
  if (isValidMessage(payload)) {
    processMessage(payload);
  }
};

function isValidMessage(value: unknown): value is Message {
  return typeof value === 'object' && value !== null && 'type' in value;
}
```

### Rule 5: Named Interface for All Props

#### Edge Case: Single-prop components
Even components with a single prop should use a named interface for consistency and future extensibility.

```typescript
// Still use a named interface
interface LoadingSpinnerProps {
  size?: 'sm' | 'md' | 'lg';
}

const LoadingSpinner = ({ size = 'md' }: LoadingSpinnerProps): JSX.Element => (
  <div className={`spinner spinner-${size}`} />
);
```

#### Edge Case: Children-only components
Components that only accept `children` should still define a props interface using `React.PropsWithChildren` or an explicit interface.

```typescript
interface LayoutProps {
  children: React.ReactNode;
}

const Layout = ({ children }: LayoutProps): JSX.Element => (
  <main className="container">{children}</main>
);
```

### Rule 8: Explicit Return Types on Exported Functions

#### Edge Case: Non-exported (internal) functions
Internal helper functions that are not exported do NOT require explicit return types. The rule only applies to the public API surface.

```typescript
// Internal helper — no return type required
const computeTotal = (items: CartItem[]) =>
  items.reduce((sum, item) => sum + item.price * item.quantity, 0);

// Exported — return type required
export const useCart = (): UseCartReturn => {
  // ...
};
```

## Modern Alternatives

### Hooks as an alternative to Container components
React hooks can replace container components in many cases. A custom hook encapsulates data fetching and logic, while the consuming component remains presentational-ish. This is acceptable as long as the hook is extracted to `hooks/` and the component doesn't grow beyond ~150 lines.

```typescript
// hooks/useProducts.ts
export const useProducts = (): UseProductsReturn => {
  const { data, error, isLoading } = useSWR<Product[]>('/api/products', fetcher);
  return { products: data ?? [], error, isLoading };
};

// Components can use the hook directly if they stay small and focused
// But if JSX grows complex, split into Container + Presentational
```

The rule of thumb: if your component has both a custom data hook AND more than ~50 lines of JSX, split it.

## FAQ

### Q: Does a component with `useRouter()` count as data-fetching?
A: No. `useRouter` provides routing state, not external data. A component using `useRouter` for navigation/params is not violating Rule 1.

### Q: Can a presentational component use `useContext`?
A: Only for theme/locale contexts that are purely presentational (e.g., `useTheme()`). If the context provides data or business state, it belongs in a container.

### Q: Should `const` enums have explicit types?
A: `const` enums and literal unions are already typed by definition. Explicit annotation is not required for these declarations — only for exported function return types.

### Q: What about `React.FC` vs plain function?
A: Either is acceptable as long as props use a named interface. `React.FC` implicitly types `children` which may not be desired — plain functions with explicit props interfaces are preferred.
