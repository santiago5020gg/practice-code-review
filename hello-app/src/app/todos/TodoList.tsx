interface Todo {
  userId: number;
  id: number;
  title: string;
  completed: boolean;
}

interface TodoListProps {
  todos: Todo[];
}

export function TodoList({ todos }: TodoListProps): JSX.Element {
  return (
    <main className="min-h-screen p-8">
      <h1 className="text-3xl font-bold mb-6">Todos</h1>
      <ul className="space-y-2">
        {todos.map((todo) => (
          <li key={todo.id} className="flex items-center gap-2">
            <span
              className={`w-4 h-4 rounded border ${todo.completed ? "bg-green-500 border-green-600" : "border-gray-400"}`}
            />
            <span className={todo.completed ? "line-through text-gray-500" : ""}>
              {todo.title}
            </span>
          </li>
        ))}
      </ul>
    </main>
  );
}
