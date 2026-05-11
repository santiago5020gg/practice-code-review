---
name: container-presentational-ts-strictness
description: Enforces Container-Presentational component separation and TypeScript strictness rules — no mixed data-fetching/rendering, no `any`, named prop interfaces, explicit return types
when_to_use: "TRIGGER when: files match **/*.ts, **/*.tsx. SKIP when: *.config.ts, next.config.*, __generated__/, *.generated.ts"
effort: medium
user-invocable: false
---

# Container-Presentational Pattern & TypeScript Strictness

## Scope

**Applies to:** `**/*.ts`, `**/*.tsx`
**Excludes:** `*.config.ts`, `next.config.*`, `__generated__/`, `*.generated.ts`
**Extensions:** .ts, .tsx

## Rules

### Rule 1: No Mixed Data-Fetching and Rendering
**Severity:** Critical
**Description:** A component must not both fetch/manage data AND render significant UI. Components that import data-fetching utilities (useSWR, fetch, axios, react-query) and also contain substantial JSX must be split into a container (data) and a presentational (UI) component.
**Violation:** A single component imports `useSWR`, `fetch`, or similar AND contains more than trivial JSX rendering (e.g., maps over data, renders styled lists/cards).
**Correct:** Data fetching lives in a container component or custom hook; rendering lives in a separate presentational component that receives data via props.

**Example violation:**
```typescript
import useSWR from 'swr';

const ProductList = () => {
  const { data, isLoading } = useSWR<Product[]>('/api/products', fetcher);
  if (isLoading) return <div>Loading...</div>;
  return (
    <section className="grid grid-cols-3 gap-6 p-4">
      {data?.map((p) => (
        <div key={p.id} className="rounded-lg border p-4">
          <h3>{p.title}</h3>
          <p>${p.price}</p>
        </div>
      ))}
    </section>
  );
};
```

**Example fix:**
```typescript
// ProductList.tsx (Presentational)
interface ProductListProps {
  products: Product[];
}

const ProductList = ({ products }: ProductListProps): JSX.Element => (
  <section className="grid grid-cols-3 gap-6 p-4">
    {products.map((p) => (
      <ProductCard key={p.id} product={p} />
    ))}
  </section>
);

// ProductListContainer.tsx (Container)
const ProductListContainer = (): JSX.Element => {
  const { products, isLoading, error } = useProducts();
  if (isLoading) return <LoadingSpinner />;
  if (error) return <ErrorMessage message="Failed to load products" />;
  return <ProductList products={products} />;
};
```

### Rule 2: Presentational Components Must Be Pure
**Severity:** Critical
**Description:** Presentational components must only be concerned with how things look. They receive all data through props, contain no data fetching, no API calls, and no business logic. Local UI state (toggles, focus) is acceptable.
**Violation:** A component in `components/` imports `useSWR`, `fetch`, `axios`, or performs API calls, state mutations, or business logic transformations.
**Correct:** The component accepts data and callbacks via typed props and renders UI only.

**Example violation:**
```typescript
// components/UserCard.tsx
const UserCard = ({ userId }: { userId: string }) => {
  const { data: user } = useSWR(`/api/users/${userId}`, fetcher);
  const handleDelete = async () => {
    await fetch(`/api/users/${userId}`, { method: 'DELETE' });
  };
  return (
    <div>
      <h2>{user?.name}</h2>
      <button onClick={handleDelete}>Delete</button>
    </div>
  );
};
```

**Example fix:**
```typescript
// components/UserCard.tsx
interface UserCardProps {
  user: User;
  onDelete: () => void;
}

const UserCard = ({ user, onDelete }: UserCardProps): JSX.Element => (
  <div>
    <h2>{user.name}</h2>
    <button onClick={onDelete}>Delete</button>
  </div>
);
```

### Rule 3: Container Components Must Not Contain Complex JSX
**Severity:** Critical
**Description:** Container components are concerned with how things work — data fetching, state management, business logic. They should render only their presentational children with minimal wrapper markup. No complex styling or layout beyond basic composition.
**Violation:** A container component contains significant styled JSX (grid layouts, styled cards, lists with complex markup) instead of delegating rendering to a presentational component.
**Correct:** Container handles data/logic and passes it to a presentational child component.

**Example violation:**
```typescript
// containers/DashboardContainer.tsx
const DashboardContainer = () => {
  const { data: stats } = useStats();
  const { data: alerts } = useAlerts();
  return (
    <main className="flex flex-col gap-8 p-6 bg-gray-50 min-h-screen">
      <header className="flex items-center justify-between border-b pb-4">
        <h1 className="text-2xl font-bold">{stats?.title}</h1>
        <span className="text-sm text-gray-500">{stats?.lastUpdated}</span>
      </header>
      <div className="grid grid-cols-3 gap-4">
        {alerts?.map((a) => (
          <div key={a.id} className="rounded border p-3 shadow-sm">
            <p className="font-medium">{a.message}</p>
          </div>
        ))}
      </div>
    </main>
  );
};
```

**Example fix:**
```typescript
// containers/DashboardContainer.tsx
const DashboardContainer = (): JSX.Element => {
  const { stats, isLoading: statsLoading } = useStats();
  const { alerts, isLoading: alertsLoading } = useAlerts();
  if (statsLoading || alertsLoading) return <LoadingSpinner />;
  return <Dashboard stats={stats} alerts={alerts} />;
};
```

### Rule 4: No `any` Type
**Severity:** Critical
**Description:** The `any` type disables TypeScript's type checking entirely. Use `unknown` with type guards when the type is genuinely unknown, or define a proper type/interface.
**Violation:** Any use of `: any`, `as any`, or `<any>` in type annotations.
**Correct:** Use specific types, `unknown` + type guards, or generic type parameters.

**Example violation:**
```typescript
const fetchData = async (url: string): Promise<any> => {
  const res = await fetch(url);
  return res.json();
};

const handleEvent = (event: any) => {
  console.log(event.target.value);
};
```

**Example fix:**
```typescript
interface ApiResponse<T> {
  data: T;
  status: number;
}

const fetchData = async <T>(url: string): Promise<ApiResponse<T>> => {
  const res = await fetch(url);
  return res.json() as Promise<ApiResponse<T>>;
};

const handleEvent = (event: React.ChangeEvent<HTMLInputElement>): void => {
  console.log(event.target.value);
};
```

### Rule 5: Named Interface for All Props
**Severity:** Critical
**Description:** All component props must be defined as a named interface (e.g., `ButtonProps`). Inline anonymous types in component parameters reduce readability, reusability, and IDE support.
**Violation:** A component uses inline type annotations like `({ title, price }: { title: string; price: number })` instead of a named interface.
**Correct:** Define a `ComponentNameProps` interface and reference it in the component signature.

**Example violation:**
```typescript
const ProductCard = ({ title, price, onAdd }: { title: string; price: number; onAdd: () => void }) => (
  <div>
    <h3>{title}</h3>
    <p>${price}</p>
    <button onClick={onAdd}>Add</button>
  </div>
);
```

**Example fix:**
```typescript
interface ProductCardProps {
  title: string;
  price: number;
  onAdd: () => void;
}

const ProductCard = ({ title, price, onAdd }: ProductCardProps): JSX.Element => (
  <div>
    <h3>{title}</h3>
    <p>${price}</p>
    <button onClick={onAdd}>Add</button>
  </div>
);
```

### Rule 6: No `as` Assertions Without Comment
**Severity:** Critical
**Description:** Type assertions (`as SomeType`) bypass TypeScript's type checker. Every assertion must include a comment explaining why it is safe and necessary. Prefer type guards or proper typing instead.
**Violation:** Use of `as SomeType` without an adjacent comment explaining the reasoning.
**Correct:** Either remove the assertion by using type guards/proper typing, or add a comment explaining why the assertion is safe.

**Example violation:**
```typescript
const element = document.getElementById('root') as HTMLDivElement;
const config = JSON.parse(rawConfig) as AppConfig;
```

**Example fix:**
```typescript
// getElementById is guaranteed non-null here because this runs after DOMContentLoaded
const element = document.getElementById('root') as HTMLDivElement;

// rawConfig is validated by the schema loader before reaching this point
const config = JSON.parse(rawConfig) as AppConfig;
```

### Rule 7: No `@ts-ignore` or `@ts-expect-error`
**Severity:** Critical
**Description:** Suppression comments hide type errors instead of fixing them. The underlying type issue must be resolved properly — either by fixing the types, adding type guards, or restructuring the code.
**Violation:** Any line containing `@ts-ignore` or `@ts-expect-error`.
**Correct:** Fix the type error. If the error comes from a third-party library, add proper type declarations or use a typed wrapper.

**Example violation:**
```typescript
// @ts-ignore
const result = someUntypedLibrary.doThing(data);

// @ts-expect-error - TODO fix later
const value: string = computeValue();
```

**Example fix:**
```typescript
import type { LibraryResult } from 'some-untyped-library';

const result: LibraryResult = someUntypedLibrary.doThing(data);

const value: string = String(computeValue());
```

### Rule 8: Explicit Return Types on Exported Functions
**Severity:** Critical
**Description:** All exported functions, hooks, and components must have explicit return type annotations. This improves documentation, catches unintended return type changes, and makes APIs explicit.
**Violation:** An exported function or hook has no return type annotation (relies on inference).
**Correct:** Add an explicit return type to the function signature.

**Example violation:**
```typescript
export const useProducts = () => {
  const { data, error, isLoading } = useSWR<Product[]>('/api/products', fetcher);
  return { products: data ?? [], error, isLoading };
};

export const formatPrice = (cents: number) => {
  return `$${(cents / 100).toFixed(2)}`;
};
```

**Example fix:**
```typescript
interface UseProductsReturn {
  products: Product[];
  error: Error | undefined;
  isLoading: boolean;
}

export const useProducts = (): UseProductsReturn => {
  const { data, error, isLoading } = useSWR<Product[]>('/api/products', fetcher);
  return { products: data ?? [], error, isLoading };
};

export const formatPrice = (cents: number): string => {
  return `$${(cents / 100).toFixed(2)}`;
};
```
