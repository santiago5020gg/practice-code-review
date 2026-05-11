import { TodoList } from "./TodoList";

interface Todo {
  userId: number;
  id: number;
  title: string;
  completed: boolean;
}

async function getTodos(): Promise<Todo[]> {
  const res = await fetch("https://jsonplaceholder.typicode.com/todos");
  return res.json();
}

export default async function TodosPage(): Promise<JSX.Element> {
  const todos = await getTodos();

  return <TodoList todos={todos} />;
}
